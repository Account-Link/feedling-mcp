#!/usr/bin/env python3
"""
Feedling backend API test suite.

Usage:
    python test_api.py                        # runs against http://localhost:5001
    python test_api.py http://54.209.126.4:5001

Tests cover:
    1. Read endpoints (screen/analyze, frames, tokens)
    2. Chat: send message, fetch history, OpenClaw response
    3. Long-poll: timeout case + immediate wake-up case
    4. Full round-trip: user sends → poll wakes → OpenClaw replies → visible in history
    5. Bootstrap endpoint
    6. Identity card (init / get / nudge)
    7. Memory garden (add / list / get / delete)
"""

import sys
import threading
import time
import uuid

import requests

BASE_URL = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:5001"

PASS = "\033[92m✓\033[0m"
FAIL = "\033[91m✗\033[0m"
SKIP = "\033[93m~\033[0m"

_failures = []


def check(name: str, condition: bool, detail: str = ""):
    if condition:
        print(f"  {PASS} {name}")
    else:
        print(f"  {FAIL} {name}" + (f" — {detail}" if detail else ""))
        _failures.append(name)


def section(title: str):
    print(f"\n{'─' * 50}")
    print(f"  {title}")
    print(f"{'─' * 50}")


# ---------------------------------------------------------------------------
# 1. Health / read endpoints
# ---------------------------------------------------------------------------

section("1. Read endpoints")

r = requests.get(f"{BASE_URL}/v1/screen/analyze", timeout=5)
check("GET /v1/screen/analyze returns 200", r.status_code == 200)
body = r.json()
check("analyze has 'active' field", "active" in body)
check("analyze has 'rate_limit_ok' field", "rate_limit_ok" in body)

r = requests.get(f"{BASE_URL}/v1/screen/frames", timeout=5)
check("GET /v1/screen/frames returns 200", r.status_code == 200)
check("frames response has 'frames' list", "frames" in r.json())

r = requests.get(f"{BASE_URL}/v1/push/tokens", timeout=5)
check("GET /v1/push/tokens returns 200", r.status_code == 200)
check("tokens response has 'tokens' list", "tokens" in r.json())

# ---------------------------------------------------------------------------
# 2. Chat — basic send + history
# ---------------------------------------------------------------------------

section("2. Chat: send message and fetch history")

unique = f"test-{uuid.uuid4().hex[:8]}"
r = requests.post(f"{BASE_URL}/v1/chat/message", json={"content": unique}, timeout=5)
check("POST /v1/chat/message returns 200", r.status_code == 200)
msg_id = r.json().get("id")
msg_ts = r.json().get("ts")
check("response has 'id' and 'ts'", bool(msg_id and msg_ts))

r = requests.get(f"{BASE_URL}/v1/chat/history?limit=10", timeout=5)
check("GET /v1/chat/history returns 200", r.status_code == 200)
msgs = r.json().get("messages", [])
check("chat history contains our message", any(m.get("content") == unique for m in msgs))

# history ?since filter
r = requests.get(f"{BASE_URL}/v1/chat/history?since={msg_ts + 1}", timeout=5)
check("?since filters out older messages", not any(m.get("id") == msg_id for m in r.json().get("messages", [])))

# invalid params
r = requests.get(f"{BASE_URL}/v1/chat/history?limit=abc", timeout=5)
check("invalid limit returns 400", r.status_code == 400)

r = requests.get(f"{BASE_URL}/v1/chat/history?since=abc", timeout=5)
check("invalid since returns 400", r.status_code == 400)

# ---------------------------------------------------------------------------
# 3. Chat — OpenClaw response
# ---------------------------------------------------------------------------

section("3. Chat: OpenClaw response")

unique_reply = f"reply-{uuid.uuid4().hex[:8]}"
r = requests.post(f"{BASE_URL}/v1/chat/response", json={"content": unique_reply}, timeout=5)
check("POST /v1/chat/response returns 200", r.status_code == 200)
reply_id = r.json().get("id")
check("response has 'id'", bool(reply_id))

r = requests.get(f"{BASE_URL}/v1/chat/history?limit=10", timeout=5)
msgs = r.json().get("messages", [])
openclaw_msgs = [m for m in msgs if m.get("role") == "openclaw"]
check("openclaw message appears in history", any(m.get("content") == unique_reply for m in openclaw_msgs))
check("openclaw message has role='openclaw'", any(m.get("role") == "openclaw" for m in openclaw_msgs))

r = requests.post(f"{BASE_URL}/v1/chat/response", json={}, timeout=5)
check("empty content returns 400", r.status_code == 400)

# ---------------------------------------------------------------------------
# 4. Long-poll — timeout case
# ---------------------------------------------------------------------------

section("4. Long-poll: timeout")

# Use a very recent ts so there are no pending messages
recent_ts = time.time()
t0 = time.time()
r = requests.get(f"{BASE_URL}/v1/chat/poll?since={recent_ts}&timeout=2", timeout=10)
elapsed = time.time() - t0
check("poll returns 200", r.status_code == 200, f"got {r.status_code}: {r.text[:80]}")
if r.status_code == 200:
    body = r.json()
    check("timed_out is true when no message", body.get("timed_out") is True)
    check("messages is empty on timeout", body.get("messages") == [])
    check("timeout respected (~2s)", 1.5 <= elapsed <= 4.0, f"elapsed={elapsed:.2f}s")
else:
    _failures += ["timed_out is true when no message", "messages is empty on timeout", "timeout respected (~2s)"]

# ---------------------------------------------------------------------------
# 5. Long-poll — immediate wake-up
# ---------------------------------------------------------------------------

section("5. Long-poll: wakes up when user sends message")

poll_result = {}
poll_error = {}
poll_since = time.time()

def do_poll():
    try:
        r = requests.get(f"{BASE_URL}/v1/chat/poll?since={poll_since}&timeout=10", timeout=15)
        poll_result["status"] = r.status_code
        if r.status_code == 200:
            poll_result["body"] = r.json()
        else:
            poll_error["err"] = f"HTTP {r.status_code}: {r.text[:80]}"
    except Exception as e:
        poll_error["err"] = str(e)

# Start poll in background
t = threading.Thread(target=do_poll, daemon=True)
t.start()

# Wait briefly then send a message
time.sleep(0.3)
unique_wake = f"wake-{uuid.uuid4().hex[:8]}"
requests.post(f"{BASE_URL}/v1/chat/message", json={"content": unique_wake}, timeout=5)

t.join(timeout=8)

check("poll thread completed", not t.is_alive(), "poll hung")
if poll_error:
    check("no poll error", False, poll_error.get("err"))
else:
    check("poll returned 200", poll_result.get("status") == 200)
    body = poll_result.get("body", {})
    check("timed_out is false", body.get("timed_out") is False)
    msgs = body.get("messages", [])
    check("wake message is in poll response", any(m.get("content") == unique_wake for m in msgs))

# ---------------------------------------------------------------------------
# 6. Full round-trip: user → poll wakes → OpenClaw replies → visible in history
# ---------------------------------------------------------------------------

section("6. Full round-trip conversation")

round_ts = time.time()
round_user_msg = f"round-user-{uuid.uuid4().hex[:8]}"
round_oc_reply = f"round-openclaw-{uuid.uuid4().hex[:8]}"

poll_rt = {}

def poll_and_reply():
    """Simulate OpenClaw: long-poll, get user message, post response."""
    try:
        r = requests.get(f"{BASE_URL}/v1/chat/poll?since={round_ts}&timeout=10", timeout=15)
        poll_rt["poll_status"] = r.status_code
        if r.status_code == 200:
            poll_rt["poll_body"] = r.json()
        else:
            poll_rt["err"] = f"HTTP {r.status_code}: {r.text[:80]}"
            return
        # OpenClaw replies
        rr = requests.post(f"{BASE_URL}/v1/chat/response", json={"content": round_oc_reply}, timeout=5)
        poll_rt["reply_status"] = rr.status_code
    except Exception as e:
        poll_rt["err"] = str(e)

t = threading.Thread(target=poll_and_reply, daemon=True)
t.start()

time.sleep(0.3)
requests.post(f"{BASE_URL}/v1/chat/message", json={"content": round_user_msg}, timeout=5)
t.join(timeout=10)

check("round-trip poll completed", not t.is_alive())
if "err" not in poll_rt:
    check("poll woke up with user message", poll_rt.get("poll_body", {}).get("timed_out") is False)
    check("OpenClaw reply posted successfully", poll_rt.get("reply_status") == 200)

    # Verify both messages appear in history
    r = requests.get(f"{BASE_URL}/v1/chat/history?since={round_ts}&limit=20", timeout=5)
    all_msgs = r.json().get("messages", [])
    user_present = any(m.get("content") == round_user_msg and m.get("role") == "user" for m in all_msgs)
    oc_present = any(m.get("content") == round_oc_reply and m.get("role") == "openclaw" for m in all_msgs)
    check("user message visible in history", user_present)
    check("OpenClaw reply visible in history", oc_present)
else:
    check("no round-trip error", False, poll_rt["err"])

# ---------------------------------------------------------------------------
# 5. Bootstrap
# ---------------------------------------------------------------------------

section("5. Bootstrap")

r = requests.post(f"{BASE_URL}/v1/bootstrap", timeout=5)
check("POST /v1/bootstrap returns 200", r.status_code == 200)
if r.status_code == 200:
    body = r.json()
    check("bootstrap has 'status' field", "status" in body)
    check("status is 'first_time' or 'already_bootstrapped'",
          body.get("status") in ("first_time", "already_bootstrapped"))
    if body.get("status") == "first_time":
        check("first_time response has 'instructions'", "instructions" in body)

# ---------------------------------------------------------------------------
# 6. Identity card
# ---------------------------------------------------------------------------

section("6. Identity card")

# init (may already exist — 409 is also acceptable)
identity_payload = {
    "agent_name": "TestAgent",
    "self_introduction": "Test identity created by test_api.py",
    "dimensions": [
        {"name": "好奇", "value": 80, "description": "喜欢探索新事物"},
        {"name": "温柔", "value": 70, "description": "说话轻声细语"},
        {"name": "锐利", "value": 60, "description": "有时直接"},
        {"name": "稳定", "value": 55, "description": "情绪平稳"},
        {"name": "幽默", "value": 65, "description": "偶尔开玩笑"},
    ],
}
r = requests.post(f"{BASE_URL}/v1/identity/init", json=identity_payload, timeout=5)
check("POST /v1/identity/init returns 200 or 409", r.status_code in (200, 409))

# get
r = requests.get(f"{BASE_URL}/v1/identity/get", timeout=5)
check("GET /v1/identity/get returns 200", r.status_code == 200)
if r.status_code == 200:
    body = r.json()
    check("identity response has 'identity' key", "identity" in body)
    if "identity" in body:
        identity = body["identity"]
        check("identity has agent_name", "agent_name" in identity)
        check("identity has dimensions", "dimensions" in identity)
        check("identity has exactly 5 dimensions", len(identity.get("dimensions", [])) == 5)

# nudge
r = requests.post(
    f"{BASE_URL}/v1/identity/nudge",
    json={"dimension_name": "好奇", "delta": 1, "reason": "test nudge"},
    timeout=5,
)
check("POST /v1/identity/nudge returns 200", r.status_code == 200)

# nudge — missing required fields
r = requests.post(f"{BASE_URL}/v1/identity/nudge", json={}, timeout=5)
check("nudge with empty body returns 400", r.status_code == 400)

# ---------------------------------------------------------------------------
# 7. Memory garden
# ---------------------------------------------------------------------------

section("7. Memory garden")

# add
mem_title = f"test-mem-{uuid.uuid4().hex[:6]}"
r = requests.post(
    f"{BASE_URL}/v1/memory/add",
    json={
        "title": mem_title,
        "description": "A test memory moment created by test_api.py",
        "occurred_at": "2025-01-01T12:00:00",
        "type": "测试",
        "source": "bootstrap",
    },
    timeout=5,
)
check("POST /v1/memory/add returns 200", r.status_code == 200)
mem_id = None
if r.status_code == 200:
    mem_id = r.json().get("moment", {}).get("id")
    check("add response has moment.id", bool(mem_id))

# list
r = requests.get(f"{BASE_URL}/v1/memory/list?limit=20", timeout=5)
check("GET /v1/memory/list returns 200", r.status_code == 200)
if r.status_code == 200:
    body = r.json()
    check("list has 'moments' key", "moments" in body)
    moments = body.get("moments", [])
    check("our test moment appears in list", any(m.get("title") == mem_title for m in moments))

# get
if mem_id:
    r = requests.get(f"{BASE_URL}/v1/memory/get?id={mem_id}", timeout=5)
    check("GET /v1/memory/get returns 200", r.status_code == 200)
    if r.status_code == 200:
        check("get response has correct title", r.json().get("moment", {}).get("title") == mem_title)

# delete
if mem_id:
    r = requests.delete(f"{BASE_URL}/v1/memory/delete?id={mem_id}", timeout=5)
    check("DELETE /v1/memory/delete returns 200", r.status_code == 200)

    # confirm deletion
    r = requests.get(f"{BASE_URL}/v1/memory/get?id={mem_id}", timeout=5)
    check("get after delete returns 404", r.status_code == 404)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print(f"\n{'═' * 50}")
if _failures:
    print(f"  {FAIL} {len(_failures)} test(s) failed:")
    for f in _failures:
        print(f"     • {f}")
else:
    print(f"  {PASS} All tests passed")
print(f"{'═' * 50}\n")

sys.exit(1 if _failures else 0)
