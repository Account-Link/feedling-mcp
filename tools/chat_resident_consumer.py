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

_HEADERS = {"X-API-Key": FEEDLING_API_KEY}
log.info(
    "Starting resident consumer — mode=%s api_url=%s key=%s",
    AGENT_MODE, FEEDLING_API_URL, _mask(FEEDLING_API_KEY),
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
# Agent backends
# ---------------------------------------------------------------------------

# Known system-line patterns emitted by some CLI agents (defensive strip).
_SYSTEM_LINE_RE = re.compile(
    r"^\s*(session_id\s*:.*|---+|={3,}|\[.*\]\s*$)",
    re.IGNORECASE,
)


def _extract_text_from_cli_output(raw: str) -> str:
    """Best-effort extraction from raw CLI stdout.

    Try JSON parse first (e.g. --output-mode json).
    Fall back to line-by-line strip of known system lines.
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

    # Text path — strip system lines
    lines = [ln for ln in raw.splitlines() if not _SYSTEM_LINE_RE.match(ln)]
    return "\n".join(lines).strip()


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

def poll_chat(since: float) -> dict:
    url = f"{FEEDLING_API_URL}/v1/chat/poll"
    params = {"since": since, "timeout": POLL_TIMEOUT}
    resp = httpx.get(url, params=params, headers=_HEADERS, timeout=POLL_TIMEOUT + 10)
    resp.raise_for_status()
    return resp.json()


def post_reply(content: str) -> None:
    url = f"{FEEDLING_API_URL}/v1/chat/response"
    payload = {"content": content, "push_live_activity": False}
    resp = httpx.post(url, json=payload, headers=_HEADERS, timeout=15)
    resp.raise_for_status()


def get_latest_ts() -> float:
    url = f"{FEEDLING_API_URL}/v1/chat/history"
    resp = httpx.get(url, params={"limit": 1}, headers=_HEADERS, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    messages = data.get("messages") or data.get("history") or []
    if messages:
        return float(messages[-1].get("timestamp", 0))
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
    latest = 0.0
    for msg in messages:
        ts = float(msg.get("timestamp", 0))
        role = msg.get("role", "")
        if role != "user":
            latest = max(latest, ts)
            continue
        content = msg.get("content", "").strip()
        if not content:
            latest = max(latest, ts)
            continue

        log.info("user message [ts=%.3f]: %s", ts, content[:80])

        try:
            reply = call_agent(content)
        except Exception as e:
            log.error("agent call failed: %s — sending fallback", e)
            reply = FALLBACK_REPLY

        try:
            post_reply(reply)
            log.info("reply sent: %s", reply[:80])
        except Exception as e:
            log.error("failed to post reply: %s", e)

        latest = max(latest, ts)

    return latest


def run() -> None:
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

            messages = result.get("messages") or []
            if not messages:
                continue

            new_ts = _process_messages(messages)
            if new_ts > last_ts:
                last_ts = new_ts
                _save_checkpoint(last_ts)

        except httpx.HTTPStatusError as e:
            log.error("HTTP %d on poll: %s", e.response.status_code, e)
            consecutive_errors += 1
            time.sleep(min(2 ** consecutive_errors, 60))
        except Exception as e:
            log.error("poll error: %s", e)
            consecutive_errors += 1
            time.sleep(min(2 ** consecutive_errors, 60))

    log.info("resident consumer stopped")


if __name__ == "__main__":
    run()
