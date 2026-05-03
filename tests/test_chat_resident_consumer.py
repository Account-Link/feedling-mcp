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


# ---------------------------------------------------------------------------
# Phase 3: decrypt source unavailable cases
# ---------------------------------------------------------------------------

def test_empty_content_decrypt_source_available_replies(monkeypatch):
    """poll returns content="" but decrypt source is available and returns
    plaintext — consumer must reply using the decrypted content."""
    # Simulate poll returning empty-content message
    empty_msg = _make_msg(role="user", content="", ts=4000.0)
    # Decrypt source returns the plaintext version
    decrypted_msg = _make_msg(role="user", content="what's the weather?", ts=4000.0)

    monkeypatch.setattr(crc, "FEEDLING_ENCLAVE_URL", "https://127.0.0.1:5003")
    monkeypatch.setattr(crc, "FEEDLING_MCP_URL", "")
    monkeypatch.setattr(
        crc, "get_decrypted_history",
        lambda since, limit=20: [decrypted_msg],
    )

    with patch.object(crc, "call_agent", return_value="sunny") as mock_agent, \
         patch.object(crc, "post_reply") as mock_post:
        # Consumer uses get_decrypted_history result, not the empty poll message
        result_ts = crc._process_messages([decrypted_msg])

    mock_agent.assert_called_once_with("what's the weather?")
    mock_post.assert_called_once()
    assert result_ts == pytest.approx(4000.0)


def test_empty_content_no_decrypt_source_no_reply_no_fallback(monkeypatch):
    """poll returns content="" and no decrypt source is configured —
    consumer must skip the message silently (no reply, no fallback)."""
    monkeypatch.setattr(crc, "FEEDLING_ENCLAVE_URL", "")
    monkeypatch.setattr(crc, "FEEDLING_MCP_URL", "")
    crc._last_fallback_ts = 0.0

    msg = _make_msg(role="user", content="", ts=5000.0)

    with patch.object(crc, "call_agent") as mock_agent, \
         patch.object(crc, "post_reply") as mock_post:
        result_ts = crc._process_messages([msg])

    mock_agent.assert_not_called()
    mock_post.assert_not_called()
    assert result_ts == pytest.approx(5000.0)


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


# ---------------------------------------------------------------------------
# Phase 4: MCP client compat + transport probing + startup hard check
# ---------------------------------------------------------------------------

def test_mcp_client_headers_not_supported(monkeypatch):
    """Older fastmcp without headers= kwarg: consumer embeds key in URL instead."""
    captured_urls = []

    class _FakeClientNoHeaders:
        """Simulates a fastmcp.Client that does NOT accept headers=."""
        def __init__(self, url):  # no headers= param
            captured_urls.append(url)
        async def __aenter__(self):
            return self
        async def __aexit__(self, *_):
            pass
        async def call_tool(self, name, args):
            return []

    monkeypatch.setattr(crc, "_fastmcp_cls", _FakeClientNoHeaders)
    monkeypatch.setattr(crc, "FEEDLING_MCP_URL", "http://127.0.0.1:5002")
    monkeypatch.setattr(crc, "FEEDLING_MCP_KEY", "testkey123")
    # Pre-seed transport cache so probe is not attempted.
    monkeypatch.setattr(
        crc, "_mcp_transport_cache",
        {"http://127.0.0.1:5002": "http://127.0.0.1:5002/mcp"},
    )

    result = crc._fetch_from_mcp(0.0, 5)

    assert result == [], f"Expected empty list, got {result!r}"
    assert captured_urls, "FastMCP client was never instantiated"
    # Key must be in the URL, not passed as a headers= kwarg.
    assert "testkey123" in captured_urls[0], (
        f"Key not embedded in URL: {captured_urls[0]!r}"
    )


def test_mcp_probe_404_falls_back_to_sse(monkeypatch):
    """/mcp returns 404: probe falls back and discovers SSE transport."""
    import httpx as _httpx

    class _Resp404:
        status_code = 404

    class _RespSSE:
        status_code = 200
        def __enter__(self): return self
        def __exit__(self, *_): pass

    def _mock_post(url, **kw):
        return _Resp404()

    def _mock_stream(method, url, **kw):
        return _RespSSE()

    monkeypatch.setattr(crc, "FEEDLING_MCP_KEY", "testkey")
    monkeypatch.setattr(crc, "_mcp_transport_cache", {})

    with patch("httpx.post", _mock_post), patch("httpx.stream", _mock_stream):
        result = crc._probe_mcp_transport_sync("http://127.0.0.1:5002")

    assert result is not None, "probe returned None — expected SSE URL"
    assert "/sse" in result, f"Expected SSE URL, got {result!r}"
    assert "testkey" in result, "API key not in SSE URL"


def test_sse_only_config(monkeypatch):
    """With transport cache pointing to SSE, consumer passes that URL to FastMCP."""
    captured_urls = []

    class _FakeClientWithHeaders:
        def __init__(self, url, headers=None):
            captured_urls.append(url)
        async def __aenter__(self): return self
        async def __aexit__(self, *_): pass
        async def call_tool(self, name, args): return []

    sse_url = "http://127.0.0.1:5002/sse?key=testkey"
    monkeypatch.setattr(crc, "_fastmcp_cls", _FakeClientWithHeaders)
    monkeypatch.setattr(crc, "FEEDLING_MCP_URL", "http://127.0.0.1:5002")
    monkeypatch.setattr(crc, "FEEDLING_MCP_KEY", "testkey")
    monkeypatch.setattr(
        crc, "_mcp_transport_cache",
        {"http://127.0.0.1:5002": sse_url},
    )

    result = crc._fetch_from_mcp(0.0, 5)

    assert result == [], f"Expected empty list, got {result!r}"
    assert captured_urls, "FastMCP client was never instantiated"
    assert captured_urls[0] == sse_url, (
        f"Expected SSE URL {sse_url!r}, FastMCP received {captured_urls[0]!r}"
    )


def test_mcp_calltoolresult_content_shape(monkeypatch):
    """New MCP clients return CallToolResult objects, not lists. Ensure parser handles
    .content entries with .text and dict-like text entries."""

    class _TC:
        def __init__(self, text):
            self.text = text

    class _Result:
        def __init__(self, payload):
            self.content = [_TC(payload)]

    class _FakeClient:
        def __init__(self, url, headers=None):
            self.url = url
            self.headers = headers
        async def __aenter__(self):
            return self
        async def __aexit__(self, *_):
            pass
        async def call_tool(self, name, args):
            assert name in ("chat_history", "feedling.chat.get_history")
            assert "limit" in args
            return _Result('{"messages":[{"role":"user","content":"hi","ts":1.0}]}')

    monkeypatch.setattr(crc, "_fastmcp_cls", _FakeClient)
    monkeypatch.setattr(crc, "FEEDLING_MCP_URL", "https://mcp.feedling.app")
    monkeypatch.setattr(crc, "FEEDLING_MCP_KEY", "k")
    monkeypatch.setattr(crc, "_mcp_transport_cache", {"https://mcp.feedling.app": "https://mcp.feedling.app/sse"})

    out = crc._fetch_from_mcp(0.0, 20)
    assert isinstance(out, list)
    assert out and out[0]["content"] == "hi"


def test_sanitize_reply_text_strips_leaks_and_duplicates():
    raw = """— ✵ Hermes

------
在，Seven。
在，Seven。
我在这儿，直接说你要我现在做什么。
Reasoning:
"""
    cleaned = crc._sanitize_reply_text(raw)
    assert "Hermes" not in cleaned
    assert "Reasoning" not in cleaned
    assert cleaned == "在，Seven。\n我在这儿，直接说你要我现在做什么。"


def test_sanitize_reply_text_prefers_cjk_and_drops_english_reasoning():
    raw = """I need to interpret this as a greeting.
I'm thinking a warm tone is best.
在呢，Seven。
你继续说，我在听。"""
    cleaned = crc._sanitize_reply_text(raw)
    assert cleaned == "在呢，Seven。\n你继续说，我在听。"


def test_sanitize_reply_text_pure_english_reasoning_returns_empty():
    raw = """The user wrote \"甜！\" which likely means they are giving a compliment.
I think it's best to respond warmly and playfully."""
    cleaned = crc._sanitize_reply_text(raw)
    assert cleaned == ""


def test_normalize_agent_replies_supports_messages_array_json():
    raw = '{"messages":["在。","我在听。","继续说。"]}'
    out = crc._normalize_agent_replies(raw)
    assert out == ["在。", "我在听。", "继续说。"]
