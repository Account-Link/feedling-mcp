#!/usr/bin/env python3
"""
Feedling Chat Resident Consumer
================================
Polls /v1/chat/poll, routes each user message to a configured agent backend,
and writes the reply back via /v1/chat/response.

Supports two agent backend modes (set AGENT_MODE env var):

  http  — POST the user message to an HTTP endpoint and read the response body.
          Works with any REST-compatible agent (Hermes HTTP API, OpenClaw, etc.)

  cli   — Run a shell command with the user message passed via --query/-q flag.
          Works with any CLI agent that writes its reply to stdout.
          IMPORTANT: the CLI command MUST produce clean stdout (plain text or
          JSON only). See SKILL.md § "Chat Resident Consumer" for per-agent
          configuration requirements.

Required env vars (all keys go in CHAT_RESIDENT_ENV_FILE, never hardcoded):
  FEEDLING_API_URL      Base URL of the Feedling backend (e.g. http://localhost:5001)
  FEEDLING_API_KEY      Per-user API key from POST /v1/users/register
  AGENT_MODE            "http" or "cli"

HTTP mode:
  AGENT_HTTP_URL        Endpoint to POST user messages to
  AGENT_HTTP_TOKEN      Bearer token (optional)
  AGENT_HTTP_FIELD      JSON response field containing the reply (default: "response")

CLI mode:
  AGENT_CLI_CMD         Full command template; {message} is replaced with the
                        user's message text.
                        Example (Hermes): hermes chat -Q --output-mode json -q {message}
                        Example (plain):  mycli ask {message}

Optional:
  CHECKPOINT_FILE       Path to persist last-processed timestamp (default: /tmp/feedling_chat_checkpoint.json)
  FALLBACK_REPLY        Reply sent when agent call fails (default: built-in string)
  POLL_TIMEOUT          Long-poll timeout in seconds (default: 30)
  LOG_LEVEL             DEBUG / INFO / WARNING (default: INFO)
"""

import base64
import json
import logging
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

import httpx

# ---------------------------------------------------------------------------
# v1 Envelope encryption (same logic as mcp_server.py / _whoami_pubkeys)
# ---------------------------------------------------------------------------
# The backend's build_envelope lives in backend/content_encryption.py.
# We add that directory to the path so the consumer can encrypt replies
# without duplicating crypto code.

sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))
try:
    from content_encryption import build_envelope as _build_envelope
    _ENCRYPTION_AVAILABLE = True
except ImportError:
    _ENCRYPTION_AVAILABLE = False

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("feedling.resident")


def _mask(val: str) -> str:
    if not val or len(val) < 8:
        return "***"
    return val[:4] + "***" + val[-4:]


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

FEEDLING_API_URL = os.environ["FEEDLING_API_URL"].rstrip("/")
FEEDLING_API_KEY = os.environ["FEEDLING_API_KEY"]
AGENT_MODE = os.environ.get("AGENT_MODE", "http").lower()

AGENT_HTTP_URL = os.environ.get("AGENT_HTTP_URL", "")
AGENT_HTTP_TOKEN = os.environ.get("AGENT_HTTP_TOKEN", "")
AGENT_HTTP_FIELD = os.environ.get("AGENT_HTTP_FIELD", "response")

AGENT_CLI_CMD = os.environ.get("AGENT_CLI_CMD", "")

CHECKPOINT_FILE = Path(
    os.environ.get("CHECKPOINT_FILE", "/tmp/feedling_chat_checkpoint.json")
)
FALLBACK_REPLY = os.environ.get(
    "FALLBACK_REPLY", "（Agent 暂时无法响应，请稍后再试）"
)
POLL_TIMEOUT = int(os.environ.get("POLL_TIMEOUT", "30"))

# When set, user message content is fetched from the enclave's mirrored
# decrypt endpoints instead of relying on poll's content field (which is
# always "" for v1 encrypted messages). Point this at the enclave app URL,
# e.g. https://127.0.0.1:5003 or the same host:port as FEEDLING_ENCLAVE_URL
# in mcp_server.py.
FEEDLING_ENCLAVE_URL = os.environ.get("FEEDLING_ENCLAVE_URL", "").rstrip("/")

_HEADERS = {"X-API-Key": FEEDLING_API_KEY}

# Separate HTTP client for the enclave (self-signed TLS, verify=False).
_ENCLAVE_CLIENT: httpx.Client | None = (
    httpx.Client(timeout=20, verify=False) if FEEDLING_ENCLAVE_URL else None
)

log.info(
    "Starting resident consumer — mode=%s api_url=%s enclave=%s key=%s",
    AGENT_MODE, FEEDLING_API_URL,
    FEEDLING_ENCLAVE_URL or "not configured (poll-only mode)",
    _mask(FEEDLING_API_KEY),
)

# ---------------------------------------------------------------------------
# Checkpoint (persist last processed message timestamp)
# ---------------------------------------------------------------------------

def _load_checkpoint() -> float:
    try:
        data = json.loads(CHECKPOINT_FILE.read_text())
        return float(data.get("last_ts", 0))
    except Exception:
        return 0.0


def _save_checkpoint(ts: float) -> None:
    try:
        CHECKPOINT_FILE.write_text(json.dumps({"last_ts": ts}))
    except Exception as e:
        log.warning("checkpoint write failed: %s", e)


# ---------------------------------------------------------------------------
# Message dedup
# ---------------------------------------------------------------------------

def _msg_key(msg: dict) -> str:
    """Stable identity key: prefer explicit id field, fall back to ts:role."""
    mid = str(msg.get("id") or msg.get("message_id") or "").strip()
    if mid:
        return mid
    ts = msg.get("ts", msg.get("timestamp", 0)) or 0
    return f"{ts}:{msg.get('role', '')}"


def _mark_seen(key: str) -> bool:
    """Mark key as seen. Returns True (new) or False (already processed)."""
    if key in _seen_ids:
        return False
    _seen_ids.add(key)
    _seen_ids_order.append(key)
    if len(_seen_ids_order) > _SEEN_MAX:
        _seen_ids.discard(_seen_ids_order.pop(0))
    return True


# ---------------------------------------------------------------------------
# Enclave decrypt proxy — plaintext content source
# ---------------------------------------------------------------------------

def get_decrypted_history(since: float, limit: int = 20) -> list[dict]:
    """Fetch decrypted message history from the enclave decrypt proxy.

    The enclave mirrors /v1/chat/history and unseals K_enclave before
    responding, so agents that don't hold user_sk can read v1 envelopes.
    Returns [] if FEEDLING_ENCLAVE_URL is not configured or the call fails.
    """
    if not FEEDLING_ENCLAVE_URL or _ENCLAVE_CLIENT is None:
        return []
    try:
        resp = _ENCLAVE_CLIENT.get(
            f"{FEEDLING_ENCLAVE_URL}/v1/chat/history",
            params={"limit": limit, "since": since},
            headers=_HEADERS,
        )
        resp.raise_for_status()
        data = resp.json()
        msgs = data.get("messages") or data.get("history") or []
        # Only return messages strictly newer than the checkpoint.
        return [
            m for m in msgs
            if float(m.get("ts", m.get("timestamp", 0)) or 0) > since
        ]
    except Exception as e:
        log.warning("enclave history fetch failed: %s", e)
        return []


# ---------------------------------------------------------------------------
# Agent backends
# ---------------------------------------------------------------------------

# Decoration / system lines that are never part of the actual reply.
_NOISE_LINE_RE = re.compile(
    r"^\s*("
    r"session_id\s*:.*"      # hermes session footer
    r"|---+|={3,}"           # separator lines
    r"|\[.*\]\s*$"           # [bracket] meta lines
    r"|💭.*"                 # hermes thinking-emoji prefix
    r"|\*\*[^*]+\*\*\s*$"   # **standalone bold header**
    r"|</?think>"            # <think> XML tags
    r"|Reasoning:\s*$"       # bare "Reasoning:" label
    r")",
    re.IGNORECASE,
)


def _extract_text_from_cli_output(raw: str) -> str:
    """Best-effort extraction from raw CLI stdout.

    1. Try JSON parse first (hermes --output-mode json gives a clean field).
    2. Split into blank-line-separated paragraphs after stripping noise lines.
    3. Return the last paragraph that contains CJK characters — reasoning
       blocks are typically English and precede the Chinese reply.
    4. Fall back to the last non-empty paragraph if no CJK found.
    """
    raw = raw.strip()
    if not raw:
        return ""

    # JSON path
    try:
        obj = json.loads(raw)
        for field in ("response", "content", "text", "message", "reply"):
            if isinstance(obj.get(field), str) and obj[field].strip():
                return obj[field].strip()
    except (json.JSONDecodeError, TypeError):
        pass

    # Strip noise lines, then split into paragraphs
    clean = [ln for ln in raw.splitlines() if not _NOISE_LINE_RE.match(ln)]
    paragraphs: list[str] = []
    current: list[str] = []
    for ln in clean:
        if ln.strip():
            current.append(ln)
        else:
            if current:
                paragraphs.append("\n".join(current).strip())
                current = []
    if current:
        paragraphs.append("\n".join(current).strip())

    if not paragraphs:
        return ""

    # Prefer the last paragraph that contains CJK characters
    for para in reversed(paragraphs):
        if any("一" <= c <= "鿿" for c in para):
            return para

    return paragraphs[-1]


def call_agent_http(message: str) -> str:
    if not AGENT_HTTP_URL:
        raise ValueError("AGENT_HTTP_URL is not set for http mode")
    headers = {"Content-Type": "application/json"}
    if AGENT_HTTP_TOKEN:
        headers["Authorization"] = f"Bearer {AGENT_HTTP_TOKEN}"
    payload = {"message": message}
    resp = httpx.post(AGENT_HTTP_URL, json=payload, headers=headers, timeout=60)
    resp.raise_for_status()
    body = resp.json()
    if isinstance(body, dict):
        for field in (AGENT_HTTP_FIELD, "response", "content", "text", "reply"):
            if isinstance(body.get(field), str) and body[field].strip():
                return body[field].strip()
        raise ValueError(f"response field not found in: {list(body.keys())}")
    if isinstance(body, str):
        return body.strip()
    raise ValueError(f"unexpected response type: {type(body)}")


def call_agent_cli(message: str) -> str:
    if not AGENT_CLI_CMD:
        raise ValueError("AGENT_CLI_CMD is not set for cli mode")
    cmd_str = AGENT_CLI_CMD.replace("{message}", message)
    cmd = shlex.split(cmd_str)
    log.debug("running cli agent: %s", cmd)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        log.warning("cli agent exited %d: %s", result.returncode, result.stderr[:200])
    raw = result.stdout
    text = _extract_text_from_cli_output(raw)
    if not text:
        raise ValueError(
            f"cli agent produced no usable output (exit={result.returncode})"
        )
    return text


def call_agent(message: str) -> str:
    if AGENT_MODE == "http":
        return call_agent_http(message)
    elif AGENT_MODE == "cli":
        return call_agent_cli(message)
    else:
        raise ValueError(f"unknown AGENT_MODE: {AGENT_MODE!r}")


# ---------------------------------------------------------------------------
# Feedling API helpers
# ---------------------------------------------------------------------------

# Cached from /v1/users/whoami at startup. Refreshed on 401/encryption error.
_whoami_cache: dict = {"user_id": "", "user_pk": None, "enclave_pk": None}

# Fallback deduplication — don't flood the user if the agent repeatedly fails.
FALLBACK_COOLDOWN = int(os.environ.get("FALLBACK_COOLDOWN", "60"))
_last_fallback_ts: float = 0.0

# Message dedup — rolling window prevents reprocessing the same message on
# restart with a stale checkpoint or if poll races with checkpoint save.
_seen_ids: set[str] = set()
_seen_ids_order: list[str] = []
_SEEN_MAX = 500


def _load_whoami() -> bool:
    """Fetch encryption keys from /v1/users/whoami and cache them.

    Returns True if both the user pubkey and enclave pubkey were obtained.
    A missing enclave pubkey is still usable (visibility falls back to
    local_only), but shared-visibility envelopes require it.
    """
    try:
        resp = httpx.get(
            f"{FEEDLING_API_URL}/v1/users/whoami", headers=_HEADERS, timeout=10
        )
        resp.raise_for_status()
        info = resp.json()
    except Exception as e:
        log.warning("whoami fetch failed: %s", e)
        return False

    user_id = info.get("user_id", "") or ""
    user_pk_b64 = (info.get("public_key") or "").strip()
    enc_pk_hex = (info.get("enclave_content_public_key_hex") or "").strip()

    try:
        user_pk = base64.b64decode(user_pk_b64) if user_pk_b64 else None
        if user_pk is not None and len(user_pk) != 32:
            user_pk = None
    except Exception:
        user_pk = None

    try:
        enc_pk = bytes.fromhex(enc_pk_hex) if enc_pk_hex else None
        if enc_pk is not None and len(enc_pk) != 32:
            enc_pk = None
    except Exception:
        enc_pk = None

    _whoami_cache.update(user_id=user_id, user_pk=user_pk, enclave_pk=enc_pk)
    log.info(
        "whoami loaded — user_id=%s user_pk=%s enclave_pk=%s",
        user_id,
        "ok" if user_pk else "MISSING",
        "ok" if enc_pk else "missing (local_only fallback)",
    )
    return bool(user_id and user_pk)


def poll_chat(since: float) -> dict:
    url = f"{FEEDLING_API_URL}/v1/chat/poll"
    params = {"since": since, "timeout": POLL_TIMEOUT}
    resp = httpx.get(url, params=params, headers=_HEADERS, timeout=POLL_TIMEOUT + 10)
    resp.raise_for_status()
    return resp.json()


def post_reply(content: str) -> None:
    """Post agent reply as a v1 ciphertext envelope.

    Falls back to plaintext only when encryption is unavailable — this will
    return 400 on v1 backends and is logged as an error so it's visible.
    """
    url = f"{FEEDLING_API_URL}/v1/chat/response"

    user_id = _whoami_cache["user_id"]
    user_pk: bytes | None = _whoami_cache["user_pk"]
    enc_pk: bytes | None = _whoami_cache["enclave_pk"]

    if _ENCRYPTION_AVAILABLE and user_id and user_pk:
        visibility = "shared" if enc_pk else "local_only"
        envelope = _build_envelope(
            plaintext=content.encode("utf-8"),
            owner_user_id=user_id,
            user_pk_bytes=user_pk,
            enclave_pk_bytes=enc_pk,
            visibility=visibility,
        )
        resp = httpx.post(
            url, json={"envelope": envelope}, headers=_HEADERS, timeout=15
        )
        resp.raise_for_status()
        return

    # Encryption unavailable — plaintext path (will 400 on v1 backends).
    log.error(
        "ENCRYPTION UNAVAILABLE — posting plaintext will fail on v1 backends. "
        "Ensure content_encryption.py is importable and whoami succeeded."
    )
    resp = httpx.post(
        url, json={"content": content, "push_live_activity": False},
        headers=_HEADERS, timeout=15,
    )
    resp.raise_for_status()


def get_latest_ts() -> float:
    url = f"{FEEDLING_API_URL}/v1/chat/history"
    resp = httpx.get(url, params={"limit": 1}, headers=_HEADERS, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    messages = data.get("messages") or data.get("history") or []
    if messages:
        m = messages[-1]
        return float(m.get("ts", m.get("timestamp", 0)) or 0)
    return 0.0


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

_running = True


def _handle_signal(signum, _frame):
    global _running
    log.info("received signal %d — shutting down", signum)
    _running = False


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def _process_messages(messages: list) -> float:
    """Process a batch of messages, return the highest timestamp seen."""
    global _last_fallback_ts
    latest = 0.0
    for msg in messages:
        # Tolerate both "ts" and "timestamp" key names across API versions.
        ts = float(msg.get("ts", msg.get("timestamp", 0)) or 0)
        role = msg.get("role", "")
        if role != "user":
            latest = max(latest, ts)
            continue

        # Idempotency — skip messages already processed in this session.
        key = _msg_key(msg)
        if not _mark_seen(key):
            log.debug("skipping already-processed message key=%s", key)
            latest = max(latest, ts)
            continue

        content = msg.get("content", "").strip()
        if not content:
            # No plaintext available — either enclave not configured or decrypt
            # failed. Never send a fallback for invisible content.
            log.warning(
                "user message has no plaintext content ts=%.3f "
                "(configure FEEDLING_ENCLAVE_URL to enable decryption)",
                ts,
            )
            latest = max(latest, ts)
            continue

        log.info("user message [ts=%.3f]: %s", ts, content[:80])

        try:
            reply = call_agent(content)
        except Exception as e:
            log.error("agent call failed: %s", e)
            now = time.time()
            if now - _last_fallback_ts >= FALLBACK_COOLDOWN:
                reply = FALLBACK_REPLY
                _last_fallback_ts = now
                log.warning("sending fallback reply (cooldown starts)")
            else:
                log.warning(
                    "fallback suppressed — cooldown active (last sent %.0fs ago)",
                    now - _last_fallback_ts,
                )
                latest = max(latest, ts)
                continue

        try:
            post_reply(reply)
            log.info("reply sent: %s", reply[:80])
        except Exception as e:
            log.error("failed to post reply: %s", e)

        latest = max(latest, ts)

    return latest


def run() -> None:
    # Hard auth check before entering the poll loop.
    # A missing user_id or public_key means every encrypted reply will fail;
    # exit now so the operator sees an immediate error instead of silent no-ops.
    if not _ENCRYPTION_AVAILABLE:
        log.critical(
            "content_encryption module not found — v1 envelope posting disabled. "
            "Make sure the consumer runs from the feedling-mcp repo root."
        )
        sys.exit(1)

    if not _load_whoami():
        log.critical(
            "whoami failed at startup — cannot obtain user_id or public_key. "
            "Check FEEDLING_API_URL and FEEDLING_API_KEY, then restart."
        )
        sys.exit(1)

    last_ts = _load_checkpoint()

    if last_ts == 0.0:
        try:
            last_ts = get_latest_ts()
            log.info("no checkpoint — seeding from history ts=%.3f", last_ts)
        except Exception as e:
            log.warning("could not seed from history: %s", e)

    _save_checkpoint(last_ts)
    log.info("starting poll loop — last_ts=%.3f poll_timeout=%ds", last_ts, POLL_TIMEOUT)

    consecutive_errors = 0

    while _running:
        try:
            result = poll_chat(last_ts)
            consecutive_errors = 0

            if result.get("timed_out"):
                continue

            poll_messages = result.get("messages") or []
            if not poll_messages:
                continue

            # poll is used only as a trigger — its content fields are "" for
            # v1 encrypted envelopes. When the enclave decrypt proxy is
            # configured, replace the message list with decrypted history.
            if FEEDLING_ENCLAVE_URL:
                messages = get_decrypted_history(since=last_ts, limit=20)
                if not messages:
                    # Enclave returned nothing — advance checkpoint from poll
                    # timestamps so we don't replay these events next cycle.
                    log.debug("poll triggered but enclave returned no new messages")
                    for m in poll_messages:
                        pts = float(m.get("ts", m.get("timestamp", 0)) or 0)
                        if pts > last_ts:
                            last_ts = pts
                            _save_checkpoint(last_ts)
                    continue
            else:
                messages = poll_messages

            new_ts = _process_messages(messages)
            if new_ts > last_ts:
                last_ts = new_ts
                _save_checkpoint(last_ts)

        except httpx.HTTPStatusError as e:
            status = e.response.status_code
            log.error("HTTP %d on poll: %s", status, e)
            if status == 401:
                log.warning("401 on poll — API key may have changed; refreshing whoami")
                if not _load_whoami():
                    log.critical(
                        "whoami returned 401 — API key is invalid. "
                        "Update FEEDLING_API_KEY and restart the service."
                    )
                    sys.exit(1)
            consecutive_errors += 1
            time.sleep(min(2 ** consecutive_errors, 60))
        except Exception as e:
            log.error("poll error: %s", e)
            consecutive_errors += 1
            time.sleep(min(2 ** consecutive_errors, 60))

    log.info("resident consumer stopped")


if __name__ == "__main__":
    run()
