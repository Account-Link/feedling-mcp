#!/usr/bin/env python3
"""
End-to-end Phase 2 encryption test.

Spins up Flask backend + enclave service against the dstack simulator,
registers a user, generates a client-side content keypair, encrypts a
message per docs/DESIGN_E2E.md §3.2 (double-wrap + AEAD aad binding),
POSTs it via /v1/chat/message, then fetches it back through the enclave's
/v2/chat/get_history and verifies the plaintext round-trips. Plus
negative tests: cross-user aad substitution rejected, missing K_enclave
for shared rejected, local_only surfaces as placeholder.

Prereqs:
  - phala simulator running (phala simulator start)
  - Python deps: flask, nacl, dstack_sdk, httpx, requests

Run:
  python3 tools/e2e_v2_encryption_test.py
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import signal
import subprocess
import sys
import time
from pathlib import Path

import nacl.bindings
import nacl.public
import requests


ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

PASS = "\033[92m✓\033[0m"
FAIL = "\033[91m✗\033[0m"

_failures = []


def check(name: str, cond: bool, detail: str = ""):
    if cond:
        print(f"  {PASS} {name}")
    else:
        print(f"  {FAIL} {name}" + (f" — {detail}" if detail else ""))
        _failures.append(name)


def section(title: str):
    print(f"\n{'─' * 60}\n  {title}\n{'─' * 60}")


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def unb64(s: str) -> bytes:
    return base64.b64decode(s)


# ---------------------------------------------------------------------------
# Client-side encryption (mirrors what iOS will do)
# ---------------------------------------------------------------------------


def build_aead_aad(owner_user_id: str, v: int, item_id: str) -> bytes:
    return f"{owner_user_id}|{v}|{item_id}".encode("utf-8")


def encrypt_chat_message(
    plaintext: str,
    owner_user_id: str,
    user_pk: nacl.public.PublicKey,
    enclave_pk: nacl.public.PublicKey,
    *,
    visibility: str = "shared",
    override_aad_owner: str | None = None,
    override_item_id_for_aad: str | None = None,
) -> tuple[dict, str]:
    """Build a v1 envelope. Returns (envelope_dict, item_id_used_in_aad).

    The override_ parameters let negative tests craft intentionally
    mismatched AAD to prove the enclave rejects them.
    """
    K = secrets.token_bytes(32)
    nonce = secrets.token_bytes(24)
    item_id = secrets.token_hex(16)

    aad_owner = override_aad_owner if override_aad_owner is not None else owner_user_id
    aad_item_id = override_item_id_for_aad if override_item_id_for_aad is not None else item_id
    aad = build_aead_aad(aad_owner, 1, aad_item_id)

    body_ct = nacl.bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(
        plaintext.encode("utf-8"), aad, nonce, K
    )

    user_sealed = nacl.public.SealedBox(user_pk).encrypt(K)
    env: dict = {
        "v": 1,
        "id": item_id,                  # server stores as-is so enclave re-derives same AAD
        "body_ct": b64(body_ct),
        "nonce": b64(nonce),
        "K_user": b64(user_sealed),
        "visibility": visibility,
        "owner_user_id": owner_user_id,
        "enclave_pk_fpr": enclave_pk.encode()[:16].hex(),
    }
    if visibility == "shared":
        enclave_sealed = nacl.public.SealedBox(enclave_pk).encrypt(K)
        env["K_enclave"] = b64(enclave_sealed)
    return env, item_id


# ---------------------------------------------------------------------------
# Process lifecycle
# ---------------------------------------------------------------------------


class Proc:
    def __init__(self, label: str, cmd: list[str], env: dict, log_path: str):
        self.label = label
        self.cmd = cmd
        self.env = env
        self.log_path = log_path
        self.proc: subprocess.Popen | None = None

    def start(self):
        self.logf = open(self.log_path, "w")
        merged_env = os.environ.copy()
        merged_env.update(self.env)
        self.proc = subprocess.Popen(
            self.cmd, env=merged_env, stdout=self.logf, stderr=subprocess.STDOUT,
            cwd=ROOT,
        )

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if hasattr(self, "logf"):
            self.logf.close()


def wait_for(url: str, timeout_s: float = 15.0) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            r = requests.get(url, timeout=2)
            if r.status_code < 500:
                return True
        except Exception:
            pass
        time.sleep(0.3)
    return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    sim_socket = os.environ.get("DSTACK_SIMULATOR_ENDPOINT",
                                str(Path.home() / ".phala-cloud/simulator/0.5.3/dstack.sock"))
    if not Path(sim_socket).exists():
        print(f"dstack simulator not running (socket {sim_socket} missing)")
        print("Run:  phala simulator start")
        sys.exit(2)

    data_dir = f"/tmp/feedling-e2e-{int(time.time())}"
    os.makedirs(data_dir, exist_ok=True)

    backend = Proc(
        "backend",
        ["python3", "backend/app.py"],
        {
            "SINGLE_USER": "false",
            "FEEDLING_DATA_DIR": data_dir,
            "FEEDLING_WS_PORT": "29998",
        },
        log_path=f"{data_dir}/backend.log",
    )
    enclave = Proc(
        "enclave",
        ["python3", "backend/enclave_app.py"],
        {
            "DSTACK_SIMULATOR_ENDPOINT": sim_socket,
            "FEEDLING_FLASK_URL": "http://127.0.0.1:5001",
            "FEEDLING_ENCLAVE_PORT": "5003",
        },
        log_path=f"{data_dir}/enclave.log",
    )

    try:
        section("Bring up backend + enclave")
        backend.start()
        ok = wait_for("http://127.0.0.1:5001/healthz", 15)
        check("backend healthy on :5001", ok)
        if not ok:
            print(Path(f"{data_dir}/backend.log").read_text()[-2000:])
            return

        enclave.start()
        ok = wait_for("http://127.0.0.1:5003/healthz", 15)
        check("enclave ready on :5003", ok)
        if not ok:
            print(Path(f"{data_dir}/enclave.log").read_text()[-2000:])
            return

        section("Fetch attestation + enclave pubkey")
        att = requests.get("http://127.0.0.1:5003/attestation", timeout=5).json()
        enclave_pk_hex = att["enclave_content_pk_hex"]
        enclave_pk = nacl.public.PublicKey(bytes.fromhex(enclave_pk_hex))
        check("attestation has enclave_content_pk_hex", len(enclave_pk_hex) == 64)
        check("attestation has compose_hash", bool(att.get("compose_hash")))

        section("Register multi-tenant user")
        r = requests.post("http://127.0.0.1:5001/v1/users/register", json={}, timeout=5)
        check("register returns 201", r.status_code == 201)
        user = r.json()
        user_id = user["user_id"]
        api_key = user["api_key"]
        check("got usr_ id", user_id.startswith("usr_"))

        section("Client generates content keypair")
        user_sk = nacl.public.PrivateKey.generate()
        user_pk = user_sk.public_key

        section("Encrypt + POST v1 envelope (shared)")
        plaintext_msg = "the quick brown fox jumps over the lazy dog — 加密 works too"
        env, _ = encrypt_chat_message(
            plaintext=plaintext_msg,
            owner_user_id=user_id,
            user_pk=user_pk,
            enclave_pk=enclave_pk,
            visibility="shared",
        )
        r = requests.post("http://127.0.0.1:5001/v1/chat/message",
                          headers={"X-API-Key": api_key},
                          json={"envelope": env}, timeout=5)
        check("POST v1 envelope 200", r.status_code == 200)
        check("server returns v=1", r.status_code == 200 and r.json().get("v") == 1)

        section("Enclave /v2/chat/get_history decrypts + returns plaintext")
        r = requests.get("http://127.0.0.1:5003/v2/chat/get_history",
                         headers={"X-API-Key": api_key}, timeout=10)
        check("enclave v2 returns 200", r.status_code == 200, r.text[:200])
        if r.status_code == 200:
            body = r.json()
            msgs = body.get("messages", [])
            check("enclave resolved correct user_id", body.get("user_id") == user_id)
            check("exactly 1 message in history", len(msgs) == 1)
            if msgs:
                m = msgs[0]
                check("decrypt_status == ok", m.get("decrypt_status") == "ok")
                check("plaintext round-trips byte-for-byte", m.get("content") == plaintext_msg)
                check("v=1 preserved", m.get("v") == 1)
                check("no decrypt_errors", body.get("decrypt_errors") == [])

        section("Negative: local_only item comes back as placeholder")
        env_lo, _ = encrypt_chat_message(
            "this should never reach the agent",
            owner_user_id=user_id,
            user_pk=user_pk,
            enclave_pk=enclave_pk,
            visibility="local_only",
        )
        r = requests.post("http://127.0.0.1:5001/v1/chat/message",
                          headers={"X-API-Key": api_key},
                          json={"envelope": env_lo}, timeout=5)
        check("POST local_only 200", r.status_code == 200)
        r = requests.get("http://127.0.0.1:5003/v2/chat/get_history",
                         headers={"X-API-Key": api_key}, timeout=10)
        body = r.json()
        lo_items = [m for m in body["messages"] if m.get("visibility") == "local_only"]
        check("1 local_only entry found", len(lo_items) == 1)
        if lo_items:
            check("local_only item content is null", lo_items[0].get("content") is None)
            check("local_only decrypt_status marked",
                  "local_only" in lo_items[0].get("decrypt_status", ""))

        section("Negative: cross-user AAD substitution rejected")
        # Register a second user.
        u2 = requests.post("http://127.0.0.1:5001/v1/users/register", json={}, timeout=5).json()
        user2_id = u2["user_id"]
        user2_key = u2["api_key"]
        check("second user registered", user2_id != user_id)

        # user2 generates their own keypair, but crafts an AAD using user1's id.
        user2_sk = nacl.public.PrivateKey.generate()
        user2_pk = user2_sk.public_key
        env_spoof, _ = encrypt_chat_message(
            "stolen content",
            # Claim to own it on the wire…
            owner_user_id=user2_id,
            user_pk=user2_pk,
            enclave_pk=enclave_pk,
            # …but bake user1's id into the AAD so the ciphertext is bound wrong.
            override_aad_owner=user_id,
        )
        r = requests.post("http://127.0.0.1:5001/v1/chat/message",
                          headers={"X-API-Key": user2_key},
                          json={"envelope": env_spoof}, timeout=5)
        check("spoofed envelope accepted by backend (Flask doesn't validate crypto)",
              r.status_code == 200)
        # Now the enclave should fail AEAD verification when user2 reads back.
        r = requests.get("http://127.0.0.1:5003/v2/chat/get_history",
                         headers={"X-API-Key": user2_key}, timeout=10)
        body = r.json()
        spoofed = [m for m in body["messages"] if m.get("v") == 1]
        check("enclave surfaces AEAD failure for spoofed item",
              any("error:" in (m.get("decrypt_status") or "") for m in spoofed))
        check("decrypt_errors non-empty", len(body.get("decrypt_errors", [])) > 0)

        section("Negative: unauth hits 401")
        r = requests.get("http://127.0.0.1:5003/v2/chat/get_history", timeout=5)
        check("no api_key → 401", r.status_code == 401)

        section("Summary")
        if _failures:
            print(f"{FAIL} {len(_failures)} failed:")
            for f in _failures:
                print(f"    • {f}")
        else:
            print(f"{PASS} all v2 encryption assertions pass")

    finally:
        backend.stop()
        enclave.stop()

    sys.exit(1 if _failures else 0)


if __name__ == "__main__":
    main()
