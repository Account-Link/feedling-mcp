"""
Regression tests for tools/chat_resident_consumer.py
=====================================================

Run with: pytest tests/test_chat_resident_consumer.py -v
"""

import importlib
import os
import sys
import time
import types
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module bootstrap — set required env vars before the module is imported.
# ---------------------------------------------------------------------------

_ENV_DEFAULTS = {
    "FEEDLING_API_URL": "http://localhost:5001",
    "FEEDLING_API_KEY": "test_key_00000000",
    "AGENT_MODE": "http",
    "AGENT_HTTP_URL": "http://localhost:8080/chat",
    "CHECKPOINT_FILE": "/tmp/feedling_test_checkpoint.json",
}

for k, v in _ENV_DEFAULTS.items():
    os.environ.setdefault(k, v)

# Stub out content_encryption so import doesn't fail without the backend tree.
_fake_enc = types.ModuleType("content_encryption")
_fake_enc.build_envelope = lambda **kw: {"v": 1, "stub": True}
sys.modules.setdefault("content_encryption", _fake_enc)

# Add backend dir to path (needed for real import in non-test environments).
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

import tools.chat_resident_consumer as crc  # noqa: E402  (after env setup)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_msg(role="user", content="hello", ts=None, timestamp=None):
    msg = {"role": role, "content": content}
    if ts is not None:
        msg["ts"] = ts
    if timestamp is not None:
        msg["timestamp"] = timestamp
    return msg


# ---------------------------------------------------------------------------
# Case 1: user message with empty content → no fallback, checkpoint advances
# ---------------------------------------------------------------------------

def test_empty_content_no_fallback():
    """poll returns user message with empty content (encrypted envelope) —
    _process_messages must skip it without calling post_reply."""
    msgs = [_make_msg(role="user", content="", ts=1000.0)]

    with patch.object(crc, "call_agent") as mock_agent, \
         patch.object(crc, "post_reply") as mock_post:
        result_ts = crc._process_messages(msgs)

    mock_agent.assert_not_called()
    mock_post.assert_not_called()
    assert result_ts == pytest.approx(1000.0)


# ---------------------------------------------------------------------------
# Case 2: message has only "ts" key (no "timestamp") → checkpoint advances
# ---------------------------------------------------------------------------

def test_ts_key_only_advances_checkpoint():
    """API returns {"ts": 1234.5} with no "timestamp" key.
    _process_messages must still return 1234.5 so the checkpoint advances."""
    msgs = [_make_msg(role="user", content="what time is it?", ts=1234.5)]
    # ts=1234.5, no "timestamp" key

    with patch.object(crc, "call_agent", return_value="It's noon."), \
         patch.object(crc, "post_reply"):
        result_ts = crc._process_messages(msgs)

    assert result_ts == pytest.approx(1234.5)


def test_timestamp_key_only_advances_checkpoint():
    """API returns {"timestamp": 5678.9} with no "ts" key — same result."""
    msgs = [_make_msg(role="user", content="hi", timestamp=5678.9)]

    with patch.object(crc, "call_agent", return_value="hey"), \
         patch.object(crc, "post_reply"):
        result_ts = crc._process_messages(msgs)

    assert result_ts == pytest.approx(5678.9)


# ---------------------------------------------------------------------------
# Case 3: invalid API key → run() exits non-zero
# ---------------------------------------------------------------------------

def test_invalid_key_exits_on_startup():
    """If whoami returns 401 / can't get user_id at startup, run() must
    call sys.exit(1) rather than entering the poll loop silently."""
    with patch.object(crc, "_load_whoami", return_value=False), \
         patch.object(crc, "_ENCRYPTION_AVAILABLE", True), \
         pytest.raises(SystemExit) as exc_info:
        crc.run()

    assert exc_info.value.code != 0


# ---------------------------------------------------------------------------
# Bonus: fallback cooldown — agent failure should not spam the user
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Phase 2: enclave source + dedup
# ---------------------------------------------------------------------------

def test_enclave_history_used_when_configured(monkeypatch):
    """When FEEDLING_ENCLAVE_URL is set and enclave returns decrypted messages,
    _process_messages receives actual content (not the empty poll payload)."""
    monkeypatch.setattr(crc, "FEEDLING_ENCLAVE_URL", "https://127.0.0.1:5003")
    decrypted = [_make_msg(role="user", content="decrypted hello", ts=2000.0)]
    monkeypatch.setattr(crc, "get_decrypted_history", lambda since, limit=20: decrypted)

    with patch.object(crc, "call_agent", return_value="hi back") as mock_agent, \
         patch.object(crc, "post_reply"):
        result_ts = crc._process_messages(decrypted)

    mock_agent.assert_called_once_with("decrypted hello")
    assert result_ts == pytest.approx(2000.0)


def test_dedup_prevents_reprocessing_same_message():
    """The same message processed twice (e.g. on restart with stale checkpoint)
    must not trigger a second agent call."""
    crc._seen_ids.clear()
    crc._seen_ids_order.clear()

    msg = _make_msg(role="user", content="hello again", ts=3000.0)

    with patch.object(crc, "call_agent", return_value="reply") as mock_agent, \
         patch.object(crc, "post_reply"):
        crc._process_messages([msg])   # first time → processed
        crc._process_messages([msg])   # second time → deduped

    assert mock_agent.call_count == 1


def test_fallback_cooldown_suppresses_repeat():
    """If the agent fails twice in rapid succession, only the first failure
    should trigger a fallback reply; the second should be suppressed."""
    msgs = [
        _make_msg(role="user", content="msg1", ts=100.0),
        _make_msg(role="user", content="msg2", ts=101.0),
    ]

    # Reset cooldown state.
    crc._last_fallback_ts = 0.0

    with patch.object(crc, "call_agent", side_effect=RuntimeError("agent down")), \
         patch.object(crc, "post_reply") as mock_post, \
         patch("time.time", return_value=200.0):
        # First call: cooldown not active → fallback sent, _last_fallback_ts = 200.0
        crc._process_messages([msgs[0]])

    assert mock_post.call_count == 1

    with patch.object(crc, "call_agent", side_effect=RuntimeError("agent down")), \
         patch.object(crc, "post_reply") as mock_post2, \
         patch("time.time", return_value=210.0):  # only 10s later, within cooldown
        crc._process_messages([msgs[1]])

    mock_post2.assert_not_called()
