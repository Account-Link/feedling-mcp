"""ACME-DNS-01 certificate issuance for mcp.feedling.app.

Runs entirely inside the TDX CVM. Uses Cloudflare DNS API for DNS-01
challenges. Both the account key and cert key are derived from dstack-KMS
so they are stable across reboots — the cert key fingerprint stays constant
across LE renewals, keeping the attestation binding valid.

No new dependencies: uses only cryptography + httpx (already in requirements).
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

import httpx
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
import datetime as _dt

log = logging.getLogger("acme_dns01")

ACME_PROD = "https://acme-v02.api.letsencrypt.org/directory"
ACME_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"
CF_BASE = "https://api.cloudflare.com/client/v4"

# ---------------------------------------------------------------------------
# JWS helpers (RFC 7518 ES256)
# ---------------------------------------------------------------------------


def _b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _ec_jwk(key) -> dict:
    """EC P-256 JWK (public key only, sorted keys for thumbprint canonicalisation)."""
    pub = key.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )
    # RFC 7638 §3: alphabetical key order for thumbprint
    return {"crv": "P-256", "kty": "EC", "x": _b64u(pub[1:33]), "y": _b64u(pub[33:65])}


def _jwk_thumbprint(key) -> str:
    canon = json.dumps(_ec_jwk(key), separators=(",", ":"), sort_keys=True).encode()
    return _b64u(hashlib.sha256(canon).digest())


def _ecdsa_sign(key, data: bytes) -> bytes:
    """ECDSA-SHA256, raw R||S format (each 32 bytes) as required by JWS ES256."""
    sig_der = key.sign(data, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(sig_der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def _jws(key, url: str, payload, nonce: str, kid: str | None) -> dict:
    hdr: dict[str, Any] = {"alg": "ES256", "nonce": nonce, "url": url}
    if kid:
        hdr["kid"] = kid
    else:
        hdr["jwk"] = _ec_jwk(key)
    hdr_b64 = _b64u(json.dumps(hdr, separators=(",", ":")).encode())
    pay_b64 = "" if payload is None else _b64u(json.dumps(payload, separators=(",", ":")).encode())
    sig = _ecdsa_sign(key, f"{hdr_b64}.{pay_b64}".encode())
    return {"protected": hdr_b64, "payload": pay_b64, "signature": _b64u(sig)}


# ---------------------------------------------------------------------------
# ACME client
# ---------------------------------------------------------------------------


class AcmeError(Exception):
    pass


class AcmeClient:
    def __init__(self, account_key, directory_url: str, email: str):
        self._key = account_key
        self._dir_url = directory_url
        self._email = email
        self._http = httpx.Client(timeout=60)
        self._dir: dict = {}
        self._kid: str | None = None

    def _nonce(self) -> str:
        r = self._http.head(self._dir["newNonce"])
        return r.headers["Replay-Nonce"]

    def _post(self, url: str, payload, kid: str | None = None) -> httpx.Response:
        body = _jws(self._key, url, payload, self._nonce(), kid or self._kid)
        r = self._http.post(
            url, json=body, headers={"Content-Type": "application/jose+json"}
        )
        if r.status_code >= 400:
            raise AcmeError(f"ACME POST {url}: {r.status_code} {r.text[:300]}")
        return r

    def setup(self):
        """Fetch directory and register/retrieve ACME account."""
        self._dir = self._http.get(self._dir_url).json()
        r = self._post(
            self._dir["newAccount"],
            {"termsOfServiceAgreed": True, "contact": [f"mailto:{self._email}"]},
            kid=None,
        )
        self._kid = r.headers["Location"]
        log.info("ACME account ready: %s", self._kid)

    def new_order(self, domain: str) -> dict:
        r = self._post(
            self._dir["newOrder"],
            {"identifiers": [{"type": "dns", "value": domain}]},
        )
        order = r.json()
        order["_url"] = r.headers["Location"]
        return order

    def get_authz(self, authz_url: str) -> dict:
        return self._post(authz_url, None).json()  # POST-as-GET

    def respond_challenge(self, chall_url: str):
        self._post(chall_url, {})

    def poll_order(self, order_url: str, timeout: int = 180) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            order = self._post(order_url, None).json()
            if order["status"] in ("ready", "valid"):
                return order
            if order["status"] == "invalid":
                raise AcmeError(f"Order invalid: {order}")
            time.sleep(6)
        raise AcmeError("Order did not become ready within timeout")

    def finalize_and_fetch(self, finalize_url: str, order_url: str, csr_der: bytes) -> bytes:
        """Submit CSR, poll until cert URL available, return PEM chain bytes."""
        self._post(finalize_url, {"csr": _b64u(csr_der)})
        deadline = time.time() + 180
        while time.time() < deadline:
            order = self._post(order_url, None).json()
            if order.get("status") == "valid" and order.get("certificate"):
                return self._post(order["certificate"], None).content
            if order.get("status") == "invalid":
                raise AcmeError(f"Order failed after finalize: {order}")
            time.sleep(6)
        raise AcmeError("Certificate URL not available after finalize")


# ---------------------------------------------------------------------------
# Cloudflare DNS API
# ---------------------------------------------------------------------------


class CfDns:
    def __init__(self, token: str, zone_id: str):
        self._hdrs = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }
        self._zone = zone_id
        self._http = httpx.Client(timeout=30)

    def create_txt(self, name: str, value: str) -> str:
        r = self._http.post(
            f"{CF_BASE}/zones/{self._zone}/dns_records",
            headers=self._hdrs,
            json={"type": "TXT", "name": name, "content": value, "ttl": 60},
        )
        r.raise_for_status()
        rec_id = r.json()["result"]["id"]
        log.info("CF: created TXT %s (id=%s)", name, rec_id)
        return rec_id

    def delete_record(self, rec_id: str):
        try:
            r = self._http.delete(
                f"{CF_BASE}/zones/{self._zone}/dns_records/{rec_id}",
                headers=self._hdrs,
            )
            r.raise_for_status()
            log.info("CF: deleted record %s", rec_id)
        except Exception as e:
            log.warning("CF: cleanup failed for %s: %s", rec_id, e)


# ---------------------------------------------------------------------------
# CSR + cert utilities
# ---------------------------------------------------------------------------


def _make_csr(cert_key, domain: str) -> bytes:
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, domain)]))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(domain)]), critical=False
        )
    ).sign(cert_key, hashes.SHA256())
    return csr.public_bytes(serialization.Encoding.DER)


def _cert_days_remaining(cert_pem: bytes) -> int:
    cert = x509.load_pem_x509_certificate(cert_pem)
    delta = cert.not_valid_after_utc - _dt.datetime.now(_dt.timezone.utc)
    return delta.days


def _cert_pubkey_fingerprint(cert_pem: bytes) -> str:
    """sha256 of the SubjectPublicKeyInfo DER — stable across renewals."""
    chain_parts = cert_pem.split(b"-----END CERTIFICATE-----")
    leaf_pem = chain_parts[0] + b"-----END CERTIFICATE-----\n"
    cert = x509.load_pem_x509_certificate(leaf_pem)
    pub_der = cert.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return hashlib.sha256(pub_der).hexdigest()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def issue_cert(
    domain: str,
    email: str,
    cf_token: str,
    cf_zone_id: str,
    account_key,
    cert_key,
    staging: bool = False,
) -> dict[str, Any]:
    """Run ACME-DNS-01 against Let's Encrypt and return cert bundle.

    Returns {'cert_pem': bytes, 'key_pem': bytes, 'pubkey_fingerprint_hex': str}.
    Both keys must be stable EC P-256 objects (use dstack_tls.derive_key_only).
    """
    cf = CfDns(cf_token, cf_zone_id)
    acme = AcmeClient(
        account_key,
        ACME_STAGING if staging else ACME_PROD,
        email,
    )

    log.info("ACME: setting up account for %s (staging=%s)", domain, staging)
    acme.setup()

    log.info("ACME: requesting order")
    order = acme.new_order(domain)
    order_url = order["_url"]

    rec_id: str | None = None
    try:
        for authz_url in order["authorizations"]:
            authz = acme.get_authz(authz_url)
            dns_chall = next(
                c for c in authz["challenges"] if c["type"] == "dns-01"
            )
            key_auth = f"{dns_chall['token']}.{_jwk_thumbprint(account_key)}"
            txt_value = _b64u(hashlib.sha256(key_auth.encode()).digest())
            acme_name = f"_acme-challenge.{domain}"

            rec_id = cf.create_txt(acme_name, txt_value)
            log.info("ACME: waiting 40s for DNS propagation")
            time.sleep(40)  # CF propagates in <30s; extra buffer

            log.info("ACME: responding to challenge")
            acme.respond_challenge(dns_chall["url"])

        log.info("ACME: polling order for ready")
        order = acme.poll_order(order_url)

        csr_der = _make_csr(cert_key, domain)
        log.info("ACME: finalising order")
        cert_chain_pem = acme.finalize_and_fetch(order["finalize"], order_url, csr_der)
        log.info("ACME: certificate issued for %s", domain)

    finally:
        if rec_id:
            cf.delete_record(rec_id)

    key_pem = cert_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )

    return {
        "cert_pem": cert_chain_pem,
        "key_pem": key_pem,
        "pubkey_fingerprint_hex": _cert_pubkey_fingerprint(cert_chain_pem),
    }


def get_or_renew(
    domain: str,
    email: str,
    cf_token: str,
    cf_zone_id: str,
    account_key,
    cert_key,
    cache_dir: str = "/tls",
    staging: bool = False,
    renew_threshold_days: int = 30,
) -> dict[str, Any]:
    """Return cached cert if still valid; otherwise run ACME and cache result."""
    cache = Path(cache_dir)
    cert_path = cache / f"{domain}.cert.pem"
    key_path = cache / f"{domain}.key.pem"

    if cert_path.exists() and key_path.exists():
        try:
            cert_pem = cert_path.read_bytes()
            days = _cert_days_remaining(cert_pem)
            if days > renew_threshold_days:
                log.info("Cached cert for %s valid for %d more days", domain, days)
                return {
                    "cert_pem": cert_pem,
                    "key_pem": key_path.read_bytes(),
                    "pubkey_fingerprint_hex": _cert_pubkey_fingerprint(cert_pem),
                }
            log.info("Cached cert expires in %d days — renewing", days)
        except Exception as e:
            log.warning("Could not read cached cert: %s", e)

    result = issue_cert(domain, email, cf_token, cf_zone_id, account_key, cert_key, staging)
    cache.mkdir(parents=True, exist_ok=True)
    cert_path.write_bytes(result["cert_pem"])
    key_path.write_bytes(result["key_pem"])
    return result


def start_renewal_watchdog(
    domain: str,
    email: str,
    cf_token: str,
    cf_zone_id: str,
    account_key,
    cert_key,
    cache_dir: str = "/tls",
    staging: bool = False,
    check_interval_s: int = 86_400,
):
    """Daily background thread: renew cert when <30 days left, then exit.

    Docker's `restart: unless-stopped` brings the container back up with
    the freshly cached cert. This avoids complex hot-reload machinery.
    """
    def _loop():
        while True:
            time.sleep(check_interval_s)
            try:
                cert_path = Path(cache_dir) / f"{domain}.cert.pem"
                if cert_path.exists():
                    days = _cert_days_remaining(cert_path.read_bytes())
                    if days > 30:
                        log.info("Cert renewal check: %d days left, no action", days)
                        continue
                    log.info("Cert renewal triggered: %d days left", days)
                else:
                    log.info("Cert file missing — renewing")
                issue_cert(domain, email, cf_token, cf_zone_id, account_key, cert_key, staging)
                log.info("Cert renewed; restarting container to pick up new cert")
                os._exit(0)
            except Exception as e:
                log.error("Cert renewal failed: %s", e)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()
    log.info("Cert renewal watchdog started (check every %ds)", check_interval_s)
