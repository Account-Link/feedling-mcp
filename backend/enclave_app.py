#!/usr/bin/env python3
"""
Feedling enclave service — Phase 1 skeleton.

Runs inside the dstack TDX CVM (or the local dstack simulator during dev).
Exposes two endpoints:

    GET /attestation   — the TDX quote + published pubkeys + release info
    GET /healthz       — liveness probe (no auth)

Phase 1 scope (this file):
    - Derive the enclave content keypair via dstack KMS (bound to
      compose_hash + app_id — cannot be extracted outside this image).
    - Derive the enclave signing keypair.
    - Build REPORT_DATA binding the content pubkey + a placeholder
      TLS cert fingerprint (real TLS termination inside the enclave
      ships in Phase 3).
    - Request a TDX quote from dstack with that REPORT_DATA.
    - Serve the bundle at GET /attestation.

What's NOT here yet (future phases):
    - Phase 2: decryption tool handlers that unseal K_enclave and return
      plaintext to MCP.
    - Phase 3: the FastMCP SSE server itself moves in here; TLS terminates
      inside the enclave via rustls; cert issued via ACME-DNS-01.

See docs/DESIGN_E2E.md §5, §7 for the full architecture.
"""

from __future__ import annotations

import base64
import datetime as _dt
import hashlib
import json
import os
import ssl
import sys
import tempfile
import time
from typing import Any

import httpx
import nacl.bindings
import nacl.encoding
import nacl.exceptions
import nacl.public
import nacl.signing
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives import serialization
from cryptography.exceptions import InvalidTag
from flask import Flask, jsonify, Response, request
from dstack_sdk import DstackClient

from dstack_tls import derive_tls_cert_and_key, TLS_KEY_PATH


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# For local dev we point at the simulator; in a real CVM, dstack-sdk defaults
# to /var/run/dstack.sock inside the container.
#
# dstack-sdk checks `"DSTACK_SIMULATOR_ENDPOINT" in os.environ` — presence,
# not truthiness. An env var set to "" counts as present and makes the SDK
# try to connect to "" (EINVAL). Drop it if it's empty so the SDK falls
# through to /var/run/dstack.sock. A non-empty value means "I really do
# want the simulator" and stays put.
if os.environ.get("DSTACK_SIMULATOR_ENDPOINT", "") == "":
    os.environ.pop("DSTACK_SIMULATOR_ENDPOINT", None)

ENCLAVE_PORT = int(os.environ.get("FEEDLING_ENCLAVE_PORT", 5003))

# Phase 3: in-enclave TLS. When true, bootstrap() derives an ECDSA P-256
# keypair from dstack-KMS, issues a self-signed cert for it, binds
# sha256(cert-DER) into REPORT_DATA, and serves Flask over HTTPS on
# ENCLAVE_PORT. Clients verify by matching the presented cert's DER
# hash against the attested fingerprint — not by PKI chain, since the
# cert is self-signed on purpose (key material is bound to compose_hash
# via dstack-KMS, which is stronger than LE trust).
#
# Off by default so the local dstack simulator + curl/httpx stay HTTP.
# docker-compose.phala.yaml sets this true on real deployments.
ENCLAVE_TLS = os.environ.get("FEEDLING_ENCLAVE_TLS", "false").lower() == "true"

# Internal HTTPS (or HTTP in dev) to the non-TEE Flask backend. This is the
# only network dependency the enclave has after boot. Requests carry the
# caller's api_key so Flask's require_user resolves to the right user's
# ciphertext. The enclave never sees users.json directly.
FLASK_URL = os.environ.get("FEEDLING_FLASK_URL", "http://127.0.0.1:5001")

# Release metadata — normally injected via build-time env or read from a
# sidecar file baked into the image. For Phase 1 we accept env values with
# obvious placeholders so it's clear this isn't fabricated content.
RELEASE = {
    "git_commit": os.environ.get("FEEDLING_GIT_COMMIT", "dev"),
    "image_digest": os.environ.get("FEEDLING_IMAGE_DIGEST", "sha256:dev"),
    "built_at": os.environ.get("FEEDLING_BUILT_AT", "dev"),
    "compose_yaml_url": os.environ.get(
        "FEEDLING_COMPOSE_YAML_URL",
        "https://github.com/Account-Link/feedling-mcp/raw/main/deploy/docker-compose.yaml",
    ),
    "build_recipe_url": os.environ.get(
        "FEEDLING_BUILD_RECIPE_URL",
        "https://github.com/Account-Link/feedling-mcp/blob/main/deploy/BUILD.md",
    ),
}

# Phase 1 testnet deployment (Ethereum Sepolia, chain 11155111). Will be
# redeployed to Base Sepolia (chain 84532) before Phase 2, then to Base
# mainnet (chain 8453) before Phase 5. The default is the live Phase 1
# testnet contract; env vars override when we bring up new chains.
APP_AUTH = {
    "contract": os.environ.get(
        "FEEDLING_APP_AUTH_CONTRACT",
        "0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F",
    ),
    "chain_id": int(os.environ.get("FEEDLING_APP_AUTH_CHAIN_ID", 11155111)),
    "deploy_tx": os.environ.get(
        "FEEDLING_APP_AUTH_DEPLOY_TX",
        "0x752f213ae95f6759a86750dab9545c79c6841ad7838082ddf6ad5271d117915f",
    ),
    "explorer_base_url": os.environ.get(
        "FEEDLING_APP_AUTH_EXPLORER",
        "https://sepolia.etherscan.io",
    ),
}

# ---------------------------------------------------------------------------
# Key derivation
# ---------------------------------------------------------------------------

CONTENT_KEY_PATH = "feedling-content-v1"
SIGNING_KEY_PATH = "feedling-signing-v1"
# TLS_KEY_PATH is imported from dstack_tls so mcp_server and enclave_app
# derive from the same KMS-bound path.


def derive_keys(dstack: DstackClient) -> dict[str, Any]:
    """Derive the enclave's long-lived keypairs from dstack's KMS.

    These derivations are deterministic per (compose_hash, app_id, path) —
    so the same image running on two CVMs produces the same keys, but a
    different compose_hash produces a different key automatically.
    """
    # Content keypair: X25519 for libsodium sealed-box decryption.
    # dstack's get_key returns 32 bytes of seed which we use as the
    # X25519 private scalar directly.
    content_resp = dstack.get_key(CONTENT_KEY_PATH, "")
    content_seed = bytes.fromhex(content_resp.key) if isinstance(content_resp.key, str) else content_resp.key
    content_sk = nacl.public.PrivateKey(content_seed[:32])
    content_pk = content_sk.public_key

    # Signing keypair: Ed25519 for per-request signed decryption proofs.
    signing_resp = dstack.get_key(SIGNING_KEY_PATH, "")
    signing_seed = bytes.fromhex(signing_resp.key) if isinstance(signing_resp.key, str) else signing_resp.key
    signing_sk = nacl.signing.SigningKey(signing_seed[:32])
    signing_pk = signing_sk.verify_key

    return {
        "content_sk": content_sk,
        "content_pk": content_pk,
        "content_pk_bytes": bytes(content_pk),
        "signing_sk": signing_sk,
        "signing_pk": signing_pk,
        "signing_pk_bytes": bytes(signing_pk),
    }


# ---------------------------------------------------------------------------
# TLS cert material (Phase 3)
# ---------------------------------------------------------------------------


# Sentinel "no TLS binding" fingerprint. Before Phase 3 the bundle always
# carried this (Caddy/gateway terminated TLS). Post-Phase 3 this appears
# only when ENCLAVE_TLS=false (local dev). iOS treats all-zeros as
# "operator terminates TLS" and surfaces the amber disclosure.
PHASE1_TLS_FINGERPRINT = b"\x00" * 32


# `derive_tls_cert_and_key` is imported from `dstack_tls` so mcp_server
# (which also terminates TLS inside the enclave in Phase C) derives from
# the same path and produces the same cert.


# ---------------------------------------------------------------------------
# Attestation assembly
# ---------------------------------------------------------------------------


def build_report_data(content_pk_bytes: bytes, tls_cert_fingerprint: bytes, version_tag: bytes) -> bytes:
    """Construct the 64-byte REPORT_DATA per docs/DESIGN_E2E.md §5.1.

    Layout:
        [0:32]  sha256(content_pk || sha256(tls_cert_der) || "feedling-v1")
        [32]    version_byte
        [33]    flag_byte (bit 0: phase-1 placeholder TLS fingerprint)
        [34:64] reserved (zeros)
    """
    if len(tls_cert_fingerprint) != 32:
        raise ValueError("tls_cert_fingerprint must be 32 bytes (sha256)")
    binding = hashlib.sha256(content_pk_bytes + tls_cert_fingerprint + version_tag).digest()
    version_byte = b"\x01"
    flag_byte = b"\x01" if tls_cert_fingerprint == PHASE1_TLS_FINGERPRINT else b"\x00"
    reserved = b"\x00" * 30
    return binding + version_byte + flag_byte + reserved


def fetch_quote_and_measurements(dstack: DstackClient, report_data: bytes) -> dict[str, Any]:
    """Ask dstack for a TDX quote over our report_data, and pull the live
    measurement registers out of /info for clients to cross-check."""
    quote_resp = dstack.get_quote(report_data)
    info = dstack.info()
    tcb = info.tcb_info

    # event_log on the quote response is a JSON-encoded string; forward
    # as-is so the iOS verifier can decode if it wants to cross-check
    # RTMR values against the event chain.
    event_log_raw = getattr(quote_resp, "event_log", "") or ""

    # Parse mr_config_id directly from the raw quote bytes — the dstack SDK's
    # TcbInfo doesn't expose it, but dstack encodes compose_hash there on
    # real deployments per the convention from dstack-tutorial:
    #   mr_config_id[0]    = 0x01 (version marker)
    #   mr_config_id[1:33] = sha256(canonical(app_compose))
    #   mr_config_id[33:]  = zero padding
    # The simulator leaves mr_config_id all zeros, so the iOS auditor
    # treats a non-zero mr_config_id[0]=0x01 as an additional independent
    # confirmation of compose_hash, not a mandatory check.
    quote_hex = quote_resp.quote if isinstance(quote_resp.quote, str) else quote_resp.quote.hex()
    mr_config_id_hex = ""
    try:
        qbytes = bytes.fromhex(quote_hex)
        # TD Report body starts at offset 48; mr_config_id at body+184, 48 bytes
        mr_config_id_hex = qbytes[48 + 184:48 + 184 + 48].hex()
    except Exception:
        pass

    return {
        "tdx_quote_hex": quote_hex,
        "event_log_json": event_log_raw,
        "measurements": {
            "mrtd": tcb.mrtd,
            "rtmr0": tcb.rtmr0,
            "rtmr1": tcb.rtmr1,
            "rtmr2": tcb.rtmr2,
            "rtmr3": tcb.rtmr3,
            "mr_aggregated": tcb.mr_aggregated,
            "mr_config_id": mr_config_id_hex,
        },
        "compose_hash": info.compose_hash,
        "app_id": info.app_id,
        "instance_id": info.instance_id,
    }


# ---------------------------------------------------------------------------
# Cached attestation state
# ---------------------------------------------------------------------------

_state: dict[str, Any] = {
    "ready": False,
    "error": None,
    "content_pk_hex": None,
    "signing_pk_hex": None,
    "tls_cert_fingerprint_hex": PHASE1_TLS_FINGERPRINT.hex(),
    "tls_enabled": False,
    "tls_cert_pem": None,  # bytes; only kept for the SSLContext load path
    "tls_key_pem": None,   # bytes; only kept for the SSLContext load path
    "attestation": None,
    "booted_at": None,
}


def bootstrap():
    """Derive keys + generate attestation once at startup. Cached thereafter.

    When ENCLAVE_TLS is true we also derive an ECDSA P-256 cert bound to
    compose_hash and bake its sha256(DER) into REPORT_DATA so iOS can
    pin the TLS cert against the quote. Off → the old zero placeholder
    stays, and iOS will surface the amber "operator-terminated TLS" row.
    """
    try:
        dstack = DstackClient()
        keys = derive_keys(dstack)

        tls_fingerprint = PHASE1_TLS_FINGERPRINT
        if ENCLAVE_TLS:
            try:
                tls = derive_tls_cert_and_key(dstack)
                tls_fingerprint = tls["fingerprint"]
                _state["tls_cert_pem"] = tls["cert_pem"]
                _state["tls_key_pem"] = tls["key_pem"]
                _state["tls_enabled"] = True
            except Exception as e:
                # Refuse to boot silently without TLS when the operator
                # asked for it — iOS would show "operator terminates TLS"
                # without the operator realizing the enclave never set it
                # up. Fail loudly instead.
                raise RuntimeError(f"TLS derivation failed: {e}") from e

        report_data = build_report_data(
            content_pk_bytes=keys["content_pk_bytes"],
            tls_cert_fingerprint=tls_fingerprint,
            version_tag=b"feedling-v1",
        )
        attestation = fetch_quote_and_measurements(dstack, report_data)

        _state["content_pk_hex"] = keys["content_pk_bytes"].hex()
        _state["signing_pk_hex"] = keys["signing_pk_bytes"].hex()
        _state["tls_cert_fingerprint_hex"] = tls_fingerprint.hex()
        _state["attestation"] = attestation
        _state["booted_at"] = time.time()
        _state["ready"] = True
        print(
            f"[enclave] ready: content_pk={_state['content_pk_hex'][:16]}… "
            f"compose_hash={attestation['compose_hash'][:16]}… "
            f"tls={'yes' if _state['tls_enabled'] else 'no'}",
            flush=True,
        )
    except Exception as e:
        _state["error"] = repr(e)
        print(f"[enclave] bootstrap failed: {e}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

app = Flask(__name__)


@app.route("/healthz", methods=["GET"])
def healthz():
    if _state["ready"]:
        return jsonify({"ok": True, "ready": True})
    return jsonify({"ok": False, "ready": False, "error": _state["error"]}), 503


@app.route("/attestation", methods=["GET"])
def attestation():
    if not _state["ready"]:
        return jsonify({"error": "not_ready", "detail": _state["error"]}), 503

    att = _state["attestation"]
    bundle = {
        "tdx_quote_hex": att["tdx_quote_hex"],
        "event_log_json": att["event_log_json"],
        "measurements": att["measurements"],
        "compose_hash": att["compose_hash"],
        "app_id": att["app_id"],
        "instance_id": att["instance_id"],
        "enclave_content_pk_hex": _state["content_pk_hex"],
        "enclave_signing_pk_hex": _state["signing_pk_hex"],
        "enclave_tls_cert_fingerprint_hex": _state["tls_cert_fingerprint_hex"],
        "enclave_release": RELEASE,
        "app_auth": APP_AUTH,
        "report_data_version": 1,
        "phase": 3 if _state["tls_enabled"] else 1,
        "tls_in_enclave": _state["tls_enabled"],
        "notes": (
            "phase-3: TLS terminated inside the enclave."
            " enclave_tls_cert_fingerprint_hex = sha256(cert.DER) of the"
            " cert the TLS handshake presents. Clients must compare the"
            " live cert's DER hash to this value; do not trust the"
            " self-signed chain on its own."
            if _state["tls_enabled"] else
            "phase-1 skeleton — TLS cert binding is a placeholder (all"
            " zeros). Operator-controlled infrastructure terminates TLS."
            " Until in-enclave TLS is enabled, clients must trust the"
            " dstack-gateway operator to forward traffic unmodified."
        ),
        "booted_at": _state["booted_at"],
    }
    resp = Response(json.dumps(bundle, indent=2), mimetype="application/json")
    resp.headers["Cache-Control"] = "public, max-age=60"
    return resp


# ---------------------------------------------------------------------------
# Decryption helpers
# ---------------------------------------------------------------------------


def _extract_api_key() -> str:
    """Pull the caller's api_key from X-API-Key / Bearer / ?key=.
    Mirrors app.py's auth path so the enclave stays a thin tool-caller."""
    h = request.headers.get("X-API-Key", "").strip()
    if h:
        return h
    auth = request.headers.get("Authorization", "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return request.args.get("key", "").strip()


def _flask_get(path: str, api_key: str, params: dict | None = None) -> dict:
    """Fetch JSON from the backend Flask as the authenticated user. The
    enclave forwards the caller's key rather than using a privileged one —
    same scope the user granted, nothing more."""
    headers = {"X-API-Key": api_key} if api_key else {}
    with httpx.Client(timeout=15) as client:
        r = client.get(f"{FLASK_URL}{path}", params=params, headers=headers)
        r.raise_for_status()
        return r.json()


def _build_aead_aad(owner_user_id: str, v: int, item_id: str) -> bytes:
    """Per docs/DESIGN_E2E.md §3.4, content's AEAD additional-data must
    authenticate (owner_user_id, v, item_id). The enclave recomputes this
    from the plaintext metadata the server claims + the user_id it
    resolved the api_key to — mismatch → AEAD verification fails →
    cross-user ciphertext substitution attack is detected."""
    payload = f"{owner_user_id}|{v}|{item_id}".encode("utf-8")
    return payload


class DecryptFailure(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


_BOX_SEAL_INFO = b"feedling-box-seal-v1"


def _box_seal_open_hkdf(blob: bytes, recipient_sk_bytes: bytes) -> bytes:
    """iOS-compatible sealed-box open.

    Matches testapp/FeedlingTest/ContentEncryption.swift's BoxSeal:
      blob = ek_pub (32 bytes) || ciphertext || tag (16 bytes)
      shared = ECDH(recipient_sk, ek_pub)
      K_wrap = HKDF-SHA256(shared, info=BOX_SEAL_INFO, len=32)
      nonce  = sha256(ek_pub || recipient_pub)[:12]
      plaintext = ChaCha20-Poly1305-decrypt(ct||tag, K_wrap, nonce)

    This is NOT wire-compatible with libsodium's crypto_box_seal (which
    uses XSalsa20 + Blake2b) — we reimplement both sides to use only
    primitives CryptoKit supports natively, so iOS doesn't need a
    separate libsodium SPM dep.
    """
    if len(blob) < 32 + 16:
        raise DecryptFailure(f"box_seal blob too short: {len(blob)}")
    ek_pub = blob[:32]
    ct_plus_tag = blob[32:]

    try:
        sk = X25519PrivateKey.from_private_bytes(recipient_sk_bytes)
        ephemeral = X25519PublicKey.from_public_bytes(ek_pub)
        shared = sk.exchange(ephemeral)
    except Exception as e:
        raise DecryptFailure(f"ECDH failed: {e}")

    k_wrap = HKDF(algorithm=SHA256(), length=32, salt=None,
                  info=_BOX_SEAL_INFO).derive(shared)

    recipient_pub = sk.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw)
    nonce = hashlib.sha256(ek_pub + recipient_pub).digest()[:12]

    try:
        return ChaCha20Poly1305(k_wrap).decrypt(nonce, ct_plus_tag, None)
    except InvalidTag as e:
        raise DecryptFailure(f"box_seal tag invalid: {e}")


def _decrypt_envelope(env: dict, authorized_user_id: str, content_sk: nacl.public.PrivateKey) -> bytes:
    """Given a v1 envelope dict (from Flask chat history), return the
    plaintext body. Raises DecryptFailure on any integrity problem —
    missing fields, wrong enclave pubkey fingerprint, AEAD tag mismatch,
    owner_user_id ≠ authorized_user_id (cross-user substitution attack).
    """
    # Shape checks
    for field in ("body_ct", "nonce", "K_enclave", "owner_user_id"):
        if not env.get(field):
            raise DecryptFailure(f"envelope missing {field}")

    # Binding: whoever authorized this call must be the same user who wrote it.
    if env["owner_user_id"] != authorized_user_id:
        raise DecryptFailure(
            f"owner mismatch: envelope claims owner={env['owner_user_id']} "
            f"but caller is {authorized_user_id}"
        )

    try:
        k_enclave_sealed = base64.b64decode(env["K_enclave"])
        body_ct = base64.b64decode(env["body_ct"])
        nonce = base64.b64decode(env["nonce"])
    except Exception as e:
        raise DecryptFailure(f"base64 decode: {e}")

    # 1. Unseal K_enclave → K
    # Use the iOS-compatible HKDF+ChaCha scheme (see _box_seal_open_hkdf).
    K = _box_seal_open_hkdf(k_enclave_sealed, bytes(content_sk))

    if len(K) != 32:
        raise DecryptFailure(f"unexpected K length: {len(K)}")

    # 2. AEAD-decrypt body_ct with K + nonce, aad = owner||v||id
    # We use IETF ChaCha20-Poly1305 (12-byte nonce) because it's the AEAD
    # Apple's CryptoKit supports natively on iOS — no extra SPM dep needed.
    # See docs/DESIGN_E2E.md §3.1.
    v = int(env.get("v", 1))
    item_id = env.get("id", "")
    aad = _build_aead_aad(env["owner_user_id"], v, item_id)
    if len(nonce) != 12:
        raise DecryptFailure(f"expected 12-byte nonce, got {len(nonce)}")
    try:
        plaintext = nacl.bindings.crypto_aead_chacha20poly1305_ietf_decrypt(
            body_ct, aad, nonce, K
        )
    except nacl.exceptions.CryptoError as e:
        # AEAD failure — either tampering, wrong aad, or wrong K
        raise DecryptFailure(f"AEAD verify: {e}")

    return plaintext


# ---------------------------------------------------------------------------
# Agent-facing decrypt-and-serve handlers.
#
# These live at the SAME path as Flask's versions (/v1/chat/history,
# /v1/memory/list, /v1/identity/get) — Flask and the enclave are different
# services at different origins. Flask returns opaque envelopes; the enclave
# returns decrypted plaintext. Agents talk to the enclave; iOS + other
# internals talk to Flask. No "v2 API" — just a different service at the
# same path.
# ---------------------------------------------------------------------------


@app.route("/v1/chat/history", methods=["GET"])
def v1_chat_history():
    """Decrypt-and-serve chat history for the authenticated user.

    Query params:
      since (float, default 0): only return messages with ts > since
      limit (int,   default 200, max 200)

    The caller's api_key determines whose content gets decrypted. Items
    with visibility=local_only come back as placeholders (content = null)
    — the enclave doesn't have K_enclave for them and the agent never will.
    """
    if not _state["ready"]:
        return jsonify({"error": "not_ready", "detail": _state["error"]}), 503

    api_key = _extract_api_key()
    if not api_key:
        return jsonify({"error": "missing api_key"}), 401

    # Resolve whose content we're decrypting. In multi-tenant this returns
    # the user's usr_...; in single-user it's always "default".
    try:
        whoami = _flask_get("/v1/users/whoami", api_key)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 401:
            return jsonify({"error": "unauthorized"}), 401
        return jsonify({"error": f"backend_error: {e}"}), 502
    authorized_user_id = whoami.get("user_id", "")
    if not authorized_user_id:
        return jsonify({"error": "cannot resolve user_id"}), 401

    # Fetch the raw history (envelopes + legacy plaintext).
    since = request.args.get("since", "0")
    limit = request.args.get("limit", "200")
    try:
        hist = _flask_get(
            "/v1/chat/history",
            api_key,
            params={"since": since, "limit": limit},
        )
    except httpx.HTTPError as e:
        return jsonify({"error": f"backend_error: {e}"}), 502

    # Reconstruct content_sk here — we cached only the pubkey on boot, the
    # privkey is always in-memory under _state but we didn't store it.
    # Fix: also cache the sk. For now, re-derive once on first call.
    content_sk = _get_or_derive_content_sk()

    decrypted = []
    errors = []
    for m in hist.get("messages", []):
        v = int(m.get("v", 0))
        if v == 0:
            # Legacy plaintext path — just pass through.
            decrypted.append({
                "id": m["id"],
                "role": m["role"],
                "ts": m["ts"],
                "source": m.get("source"),
                "content": m.get("content", ""),
                "v": 0,
                "decrypt_status": "plaintext",
            })
            continue

        # v1+ envelope.
        if m.get("visibility") == "local_only":
            decrypted.append({
                "id": m["id"],
                "role": m["role"],
                "ts": m["ts"],
                "source": m.get("source"),
                "content": None,
                "v": v,
                "visibility": "local_only",
                "decrypt_status": "local_only_agent_cannot_read",
            })
            continue

        try:
            plaintext = _decrypt_envelope(m, authorized_user_id, content_sk)
            decrypted.append({
                "id": m["id"],
                "role": m["role"],
                "ts": m["ts"],
                "source": m.get("source"),
                "content": plaintext.decode("utf-8", errors="replace"),
                "v": v,
                "visibility": m.get("visibility", "shared"),
                "decrypt_status": "ok",
            })
        except DecryptFailure as e:
            # Surface the failure per-item so the agent sees partial
            # progress rather than a blanket 500 on one bad blob.
            errors.append({"id": m.get("id"), "reason": e.reason})
            decrypted.append({
                "id": m["id"],
                "role": m["role"],
                "ts": m["ts"],
                "content": None,
                "v": v,
                "decrypt_status": f"error: {e.reason}",
            })

    return jsonify({
        "user_id": authorized_user_id,
        "messages": decrypted,
        "total": hist.get("total", len(decrypted)),
        "decrypt_errors": errors,
    })


@app.route("/v1/memory/list", methods=["GET"])
def v1_memory_list():
    """Decrypt-and-serve memory garden for the authenticated user.

    Query params:
      since (ISO string, optional): pass-through to /v1/memory/list
      limit (int, default 50, max 200)
    """
    if not _state["ready"]:
        return jsonify({"error": "not_ready", "detail": _state["error"]}), 503
    api_key = _extract_api_key()
    if not api_key:
        return jsonify({"error": "missing api_key"}), 401

    try:
        whoami = _flask_get("/v1/users/whoami", api_key)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 401:
            return jsonify({"error": "unauthorized"}), 401
        return jsonify({"error": f"backend_error: {e}"}), 502
    authorized_user_id = whoami.get("user_id", "")
    if not authorized_user_id:
        return jsonify({"error": "cannot resolve user_id"}), 401

    limit = request.args.get("limit", "50")
    since = request.args.get("since", "")
    params = {"limit": limit}
    if since:
        params["since"] = since
    try:
        listing = _flask_get("/v1/memory/list", api_key, params=params)
    except httpx.HTTPError as e:
        return jsonify({"error": f"backend_error: {e}"}), 502

    content_sk = _get_or_derive_content_sk()
    decrypted = []
    errors = []
    for m in listing.get("moments", []):
        v = int(m.get("v", 0))
        base = {
            "id": m["id"],
            "occurred_at": m.get("occurred_at"),
            "created_at": m.get("created_at"),
            "source": m.get("source"),
            "v": v,
        }
        if v == 0:
            base.update({
                "title": m.get("title"),
                "description": m.get("description"),
                "type": m.get("type"),
                "decrypt_status": "plaintext",
            })
            decrypted.append(base); continue
        if m.get("visibility") == "local_only":
            base.update({
                "title": None, "description": None, "type": None,
                "visibility": "local_only",
                "decrypt_status": "local_only_agent_cannot_read",
            })
            decrypted.append(base); continue
        try:
            plaintext = _decrypt_envelope(m, authorized_user_id, content_sk)
            inner = json.loads(plaintext.decode("utf-8"))
            base.update({
                "title": inner.get("title"),
                "description": inner.get("description"),
                "type": inner.get("type"),
                "visibility": m.get("visibility", "shared"),
                "decrypt_status": "ok",
            })
        except (DecryptFailure, json.JSONDecodeError) as e:
            reason = e.reason if isinstance(e, DecryptFailure) else f"json: {e}"
            errors.append({"id": m.get("id"), "reason": reason})
            base.update({
                "title": None, "description": None, "type": None,
                "decrypt_status": f"error: {reason}",
            })
        decrypted.append(base)

    return jsonify({
        "user_id": authorized_user_id,
        "moments": decrypted,
        "total": listing.get("total", len(decrypted)),
        "decrypt_errors": errors,
    })


@app.route("/v1/identity/get", methods=["GET"])
def v1_identity_get():
    """Decrypt-and-serve the identity card for the authenticated user.

    Returns the same shape as /v1/identity/get (agent_name, self_introduction,
    dimensions[]), assembled from decrypted ciphertext when stored as v1.
    """
    if not _state["ready"]:
        return jsonify({"error": "not_ready", "detail": _state["error"]}), 503
    api_key = _extract_api_key()
    if not api_key:
        return jsonify({"error": "missing api_key"}), 401

    try:
        whoami = _flask_get("/v1/users/whoami", api_key)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 401:
            return jsonify({"error": "unauthorized"}), 401
        return jsonify({"error": f"backend_error: {e}"}), 502
    authorized_user_id = whoami.get("user_id", "")
    if not authorized_user_id:
        return jsonify({"error": "cannot resolve user_id"}), 401

    try:
        resp = _flask_get("/v1/identity/get", api_key)
    except httpx.HTTPError as e:
        return jsonify({"error": f"backend_error: {e}"}), 502

    identity = resp.get("identity")
    if identity is None:
        return jsonify({"identity": None, "user_id": authorized_user_id})

    v = int(identity.get("v", 0))
    base = {
        "v": v,
        "created_at": identity.get("created_at"),
        "updated_at": identity.get("updated_at"),
    }
    if v == 0:
        base.update({
            "agent_name": identity.get("agent_name"),
            "self_introduction": identity.get("self_introduction"),
            "dimensions": identity.get("dimensions", []),
            "decrypt_status": "plaintext",
        })
        return jsonify({"identity": base, "user_id": authorized_user_id})

    if identity.get("visibility") == "local_only":
        base.update({
            "visibility": "local_only",
            "decrypt_status": "local_only_agent_cannot_read",
        })
        return jsonify({"identity": base, "user_id": authorized_user_id})

    content_sk = _get_or_derive_content_sk()
    try:
        plaintext = _decrypt_envelope(identity, authorized_user_id, content_sk)
        inner = json.loads(plaintext.decode("utf-8"))
        base.update({
            "agent_name": inner.get("agent_name"),
            "self_introduction": inner.get("self_introduction"),
            "dimensions": inner.get("dimensions", []),
            "visibility": identity.get("visibility", "shared"),
            "decrypt_status": "ok",
        })
        return jsonify({"identity": base, "user_id": authorized_user_id})
    except (DecryptFailure, json.JSONDecodeError) as e:
        reason = e.reason if isinstance(e, DecryptFailure) else f"json: {e}"
        base.update({"decrypt_status": f"error: {reason}"})
        return jsonify({"identity": base, "user_id": authorized_user_id,
                        "decrypt_errors": [{"reason": reason}]})


def _get_or_derive_content_sk() -> nacl.public.PrivateKey:
    """Return the enclave's content X25519 private key, deriving if needed.

    bootstrap() stashes only the pubkey hex in _state — we derive on first
    use and cache in a module-level slot. This keeps the key's exposure
    surface minimal (one process-lifetime reference), not that there's
    anywhere for it to leak from inside the enclave anyway.
    """
    global _cached_content_sk
    if _cached_content_sk is not None:
        return _cached_content_sk
    dstack = DstackClient()
    keys = derive_keys(dstack)
    _cached_content_sk = keys["content_sk"]
    return _cached_content_sk


_cached_content_sk: nacl.public.PrivateKey | None = None


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


def _build_ssl_context() -> ssl.SSLContext | None:
    """Build an SSLContext from the in-memory cert/key material.

    Python's ssl.SSLContext.load_cert_chain only takes file paths; we
    materialize the PEM through NamedTemporaryFile and unlink right after
    load so nothing persists. In a TDX CVM /tmp is in-memory anyway —
    the bytes never hit persistent storage or the operator's disk.
    """
    if not _state["tls_enabled"]:
        return None
    cert_pem = _state["tls_cert_pem"]
    key_pem = _state["tls_key_pem"]
    if not cert_pem or not key_pem:
        return None

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    # Drop the ephemeral PEM paths as soon as load_cert_chain has read them.
    with tempfile.NamedTemporaryFile("wb", suffix=".pem", delete=False) as cf, \
         tempfile.NamedTemporaryFile("wb", suffix=".pem", delete=False) as kf:
        cf.write(cert_pem); cf.flush()
        kf.write(key_pem); kf.flush()
        cert_path, key_path = cf.name, kf.name
    try:
        ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)
    finally:
        for p in (cert_path, key_path):
            try: os.unlink(p)
            except OSError: pass
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


if __name__ == "__main__":
    bootstrap()
    ssl_ctx = _build_ssl_context()
    scheme = "https" if ssl_ctx else "http"
    print(f"Feedling enclave service listening on {scheme}://0.0.0.0:{ENCLAVE_PORT}", flush=True)
    app.run(host="0.0.0.0", port=ENCLAVE_PORT, debug=False, ssl_context=ssl_ctx)
