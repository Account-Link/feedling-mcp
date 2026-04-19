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

import hashlib
import json
import os
import sys
import time
from typing import Any

import nacl.signing
import nacl.public
import nacl.encoding
from flask import Flask, jsonify, Response
from dstack_sdk import DstackClient


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# For local dev we point at the simulator; in a real CVM, dstack-sdk defaults
# to /var/run/dstack.sock inside the container.
SIMULATOR_ENDPOINT = os.environ.get("DSTACK_SIMULATOR_ENDPOINT", "")
if SIMULATOR_ENDPOINT and not os.environ.get("DSTACK_SIMULATOR_ENDPOINT"):
    os.environ["DSTACK_SIMULATOR_ENDPOINT"] = SIMULATOR_ENDPOINT

ENCLAVE_PORT = int(os.environ.get("FEEDLING_ENCLAVE_PORT", 5003))

# Release metadata — normally injected via build-time env or read from a
# sidecar file baked into the image. For Phase 1 we accept env values with
# obvious placeholders so it's clear this isn't fabricated content.
RELEASE = {
    "git_commit": os.environ.get("FEEDLING_GIT_COMMIT", "dev"),
    "image_digest": os.environ.get("FEEDLING_IMAGE_DIGEST", "sha256:dev"),
    "built_at": os.environ.get("FEEDLING_BUILT_AT", "dev"),
    "compose_yaml_url": os.environ.get(
        "FEEDLING_COMPOSE_YAML_URL",
        "https://github.com/Account-Link/feedling-mcp-v1/raw/main/deploy/docker-compose.yaml",
    ),
    "build_recipe_url": os.environ.get(
        "FEEDLING_BUILD_RECIPE_URL",
        "https://github.com/Account-Link/feedling-mcp-v1/blob/main/deploy/BUILD.md",
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
# Attestation assembly
# ---------------------------------------------------------------------------


# Placeholder TLS cert fingerprint — in Phase 3 this becomes the SHA-256 of
# the DER-encoded cert we terminate TLS with inside the enclave. For Phase 1
# we use zeros and mark the bundle as "phase-1-no-tls-binding" so the iOS
# verifier doesn't mistake this for the real thing.
PHASE1_TLS_FINGERPRINT = b"\x00" * 32


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

    return {
        "tdx_quote_hex": quote_resp.quote if isinstance(quote_resp.quote, str) else quote_resp.quote.hex(),
        "event_log_json": event_log_raw,
        "measurements": {
            "mrtd": tcb.mrtd,
            "rtmr0": tcb.rtmr0,
            "rtmr1": tcb.rtmr1,
            "rtmr2": tcb.rtmr2,
            "rtmr3": tcb.rtmr3,
            "mr_aggregated": tcb.mr_aggregated,
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
    "attestation": None,
    "booted_at": None,
}


def bootstrap():
    """Derive keys + generate attestation once at startup. Cached thereafter."""
    try:
        dstack = DstackClient()
        keys = derive_keys(dstack)
        report_data = build_report_data(
            content_pk_bytes=keys["content_pk_bytes"],
            tls_cert_fingerprint=PHASE1_TLS_FINGERPRINT,
            version_tag=b"feedling-v1",
        )
        attestation = fetch_quote_and_measurements(dstack, report_data)

        _state["content_pk_hex"] = keys["content_pk_bytes"].hex()
        _state["signing_pk_hex"] = keys["signing_pk_bytes"].hex()
        _state["attestation"] = attestation
        _state["booted_at"] = time.time()
        _state["ready"] = True
        print(
            f"[enclave] ready: content_pk={_state['content_pk_hex'][:16]}… "
            f"compose_hash={attestation['compose_hash'][:16]}…",
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
        "phase": 1,
        "notes": (
            "phase-1 skeleton — TLS cert binding is a placeholder (all zeros)."
            " Real TLS-in-enclave + cert fingerprint in REPORT_DATA ships in Phase 3."
        ),
        "booted_at": _state["booted_at"],
    }
    resp = Response(json.dumps(bundle, indent=2), mimetype="application/json")
    resp.headers["Cache-Control"] = "public, max-age=60"
    return resp


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    bootstrap()
    print(f"Feedling enclave service listening on http://0.0.0.0:{ENCLAVE_PORT}", flush=True)
    app.run(host="0.0.0.0", port=ENCLAVE_PORT, debug=False)
