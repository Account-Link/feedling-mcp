import asyncio
import base64
import errno
import json
import os
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

import httpx
import jwt
import websockets
from flask import Flask, jsonify, request, send_file

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

FEEDLING_DIR = Path.home() / "feedling"
FEEDLING_DIR.mkdir(parents=True, exist_ok=True)

FRAMES_DIR = FEEDLING_DIR / "frames"
FRAMES_DIR.mkdir(parents=True, exist_ok=True)
MAX_FRAMES = 200  # keep last 200 frames on disk

# ---------------------------------------------------------------------------
# Frames storage
# ---------------------------------------------------------------------------

_frames_meta: list[dict] = []  # in-memory index: [{filename, ts, app, ocr_text, w, h}]
_frames_lock = threading.Lock()


def _frame_url(filename: str) -> str:
    """Build a public URL for a frame. Prefers FEEDLING_PUBLIC_BASE_URL env var."""
    base = os.environ.get("FEEDLING_PUBLIC_BASE_URL", "").rstrip("/")
    if not base:
        base = request.host_url.rstrip("/")
    return f"{base}/v1/screen/frames/{filename}"


def _save_frame(payload: dict):
    ts = payload.get("ts", time.time())
    img_b64 = payload.get("image", "")
    if not img_b64:
        return
    try:
        img_bytes = base64.b64decode(img_b64)
    except Exception:
        return

    filename = f"frame_{int(ts * 1000)}.jpg"
    fpath = FRAMES_DIR / filename
    fpath.write_bytes(img_bytes)

    meta = {
        "filename": filename,
        "ts": ts,
        "app": payload.get("app") or payload.get("bundle"),
        "ocr_text": payload.get("ocr_text", ""),
        "w": payload.get("w", 0),
        "h": payload.get("h", 0),
    }

    with _frames_lock:
        _frames_meta.append(meta)
        if len(_frames_meta) > MAX_FRAMES:
            removed = _frames_meta.pop(0)
            old = FRAMES_DIR / removed["filename"]
            if old.exists():
                old.unlink()

    print(f"[ingest] saved {filename} app={meta['app']} ocr={len(meta['ocr_text'])}chars")


# ---------------------------------------------------------------------------
# Push cooldown state (thread-safe + persistent)
# ---------------------------------------------------------------------------

PUSH_COOLDOWN_SECONDS = int(os.environ.get("FEEDLING_PUSH_COOLDOWN_SEC", 300))
PUSH_STATE_FILE = FEEDLING_DIR / "push_state.json"
PUSH_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)  # P1: defensive mkdir

_last_push_epoch: float = 0.0   # wall-clock time of last push (for persistence)
_last_push_mono: float = 0.0    # monotonic time of last push (for duration math)
_last_push_lock = threading.Lock()


def _load_push_state():
    """Load persisted push state on startup so cooldown survives restarts."""
    global _last_push_epoch, _last_push_mono
    try:
        if PUSH_STATE_FILE.exists():
            data = json.loads(PUSH_STATE_FILE.read_text())
            epoch = float(data.get("last_push_epoch", 0.0))
            elapsed = time.time() - epoch
            if 0 <= elapsed < PUSH_COOLDOWN_SECONDS:
                _last_push_epoch = epoch
                _last_push_mono = time.monotonic() - elapsed
                print(f"[push_state] loaded — cooldown {round(PUSH_COOLDOWN_SECONDS - elapsed)}s remaining")
            else:
                print("[push_state] loaded — cooldown already expired")
    except Exception as e:
        print(f"[push_state] failed to load: {e}")


def _record_successful_push():
    """Record a successful push delivery. Thread-safe. Persists to disk."""
    global _last_push_epoch, _last_push_mono
    with _last_push_lock:
        _last_push_epoch = time.time()
        _last_push_mono = time.monotonic()
    try:
        PUSH_STATE_FILE.write_text(json.dumps({"last_push_epoch": _last_push_epoch}))
    except Exception as e:
        print(f"[push_state] failed to save: {e}")


def _cooldown_remaining_seconds() -> float:
    """Seconds left in push cooldown. Returns 0.0 if cooldown has expired."""
    with _last_push_lock:
        elapsed = time.monotonic() - _last_push_mono
    return max(0.0, PUSH_COOLDOWN_SECONDS - elapsed)


_load_push_state()

# ---------------------------------------------------------------------------
# Push token persistence
# ---------------------------------------------------------------------------

TOKENS_FILE = FEEDLING_DIR / "tokens.json"
REGISTERED_TOKENS: list[dict] = []


def _load_tokens():
    global REGISTERED_TOKENS
    try:
        if TOKENS_FILE.exists():
            data = json.loads(TOKENS_FILE.read_text())
            REGISTERED_TOKENS = data if isinstance(data, list) else []
            print(f"[tokens] loaded {len(REGISTERED_TOKENS)} token(s)")
    except Exception as e:
        print(f"[tokens] failed to load (starting empty): {e}")
        REGISTERED_TOKENS = []


def _save_tokens():
    try:
        TOKENS_FILE.write_text(json.dumps(REGISTERED_TOKENS))
    except Exception as e:
        print(f"[tokens] failed to save: {e}")


_load_tokens()

# ---------------------------------------------------------------------------
# Chat history (persistent)
# ---------------------------------------------------------------------------

CHAT_FILE = FEEDLING_DIR / "chat.json"
MAX_CHAT_MESSAGES = 500

_chat_messages: list[dict] = []
_chat_lock = threading.Lock()


def _load_chat():
    global _chat_messages
    try:
        if CHAT_FILE.exists():
            data = json.loads(CHAT_FILE.read_text())
            _chat_messages = data if isinstance(data, list) else []
            print(f"[chat] loaded {len(_chat_messages)} message(s)")
    except Exception as e:
        print(f"[chat] failed to load (starting empty): {e}")
        _chat_messages = []


def _persist_chat():
    try:
        CHAT_FILE.write_text(json.dumps(_chat_messages))
    except Exception as e:
        print(f"[chat] failed to save: {e}")


def _append_chat(role: str, content: str, source: str = "chat") -> dict:
    """Append a message. Thread-safe, persists immediately."""
    msg = {
        "id": uuid.uuid4().hex,
        "role": role,
        "content": content,
        "ts": time.time(),
        "source": source,
    }
    with _chat_lock:
        _chat_messages.append(msg)
        if len(_chat_messages) > MAX_CHAT_MESSAGES:
            _chat_messages[:] = _chat_messages[-MAX_CHAT_MESSAGES:]
        _persist_chat()
    return msg


_load_chat()

# ---------------------------------------------------------------------------
# WebSocket ingest server
# ---------------------------------------------------------------------------

WS_PORT = int(os.environ.get("FEEDLING_WS_PORT", 9998))


async def _ws_handler(websocket):
    print(f"[ws] client connected: {websocket.remote_address}")
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                if data.get("type") == "frame":
                    threading.Thread(target=_save_frame, args=(data,), daemon=True).start()
            except Exception as e:
                print(f"[ws] parse error: {e}")
    except websockets.exceptions.ConnectionClosed:
        pass
    print("[ws] client disconnected")


async def _ws_main():
    try:
        async with websockets.serve(_ws_handler, "0.0.0.0", WS_PORT):
            print(f"[ws] WebSocket ingest server running on ws://0.0.0.0:{WS_PORT}/ingest")
            await asyncio.Future()  # run forever
    except OSError as e:
        if e.errno == errno.EADDRINUSE:
            print(f"[ws] WARNING: port {WS_PORT} already in use — WebSocket ingest disabled, HTTP continues")
        else:
            raise


def _run_ws_server():
    asyncio.run(_ws_main())


threading.Thread(target=_run_ws_server, daemon=True).start()

app = Flask(__name__)

# ---------------------------------------------------------------------------
# APNs config
# ---------------------------------------------------------------------------

TEAM_ID = "DC9JH5DRMY"
KEY_ID = "5TH55X5U7T"
BUNDLE_ID = "com.feedling.mcp"
APNS_SANDBOX = True  # True for dev/TestFlight, False for App Store

_KEY_SEARCH = [
    FEEDLING_DIR / f"AuthKey_{KEY_ID}.p8",
    Path(__file__).parent / f"AuthKey_{KEY_ID}.p8",
]
APNS_KEY = None
for _p in _KEY_SEARCH:
    if _p.exists():
        APNS_KEY = _p.read_text()
        print(f"[apns] key loaded from {_p}")
        break
if not APNS_KEY:
    print("[apns] WARNING: .p8 key not found — push endpoints will log only, not deliver")


def _make_apns_jwt() -> str:
    return jwt.encode(
        {"iss": TEAM_ID, "iat": int(time.time())},
        APNS_KEY,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def _send_apns(device_token: str, payload: dict, push_type: str, topic: str) -> dict:
    if not APNS_KEY:
        print(f"[apns] no key — logged only → {device_token[:16]}… {payload}")
        return {"status": "logged_only"}
    host = "api.sandbox.push.apple.com" if APNS_SANDBOX else "api.push.apple.com"
    url = f"https://{host}/3/device/{device_token}"
    headers = {
        "authorization": f"bearer {_make_apns_jwt()}",
        "apns-push-type": push_type,
        "apns-topic": topic,
        "apns-expiration": "0",
        "apns-priority": "10",
    }
    try:
        with httpx.Client(http2=True, timeout=10) as client:
            resp = client.post(url, json=payload, headers=headers)
        if resp.status_code == 200:
            return {"status": "delivered"}
        return {"status": "error", "code": resp.status_code, "reason": resp.text}
    except Exception as e:
        return {"status": "error", "reason": str(e)}

# ---------------------------------------------------------------------------
# Mock data
# ---------------------------------------------------------------------------

TODAY = datetime.now().strftime("%Y-%m-%d")

IOS_DATA = {
    "date": TODAY,
    "total_screen_time_minutes": 179,
    "scroll_distance_meters": 2.3,
    "pickups": 47,
    "apps": [
        {"name": "TikTok", "bundle_id": "com.zhiliaoapp.musically", "category": "Entertainment",
         "duration_minutes": 45, "sessions": 6, "first_used": "08:14", "last_used": "22:31"},
        {"name": "YouTube", "bundle_id": "com.google.ios.youtube", "category": "Entertainment",
         "duration_minutes": 35, "sessions": 4, "first_used": "12:02", "last_used": "21:45"},
        {"name": "Instagram", "bundle_id": "com.burbn.instagram", "category": "Social",
         "duration_minutes": 28, "sessions": 8, "first_used": "09:30", "last_used": "22:10"},
        {"name": "Messages", "bundle_id": "com.apple.MobileSMS", "category": "Communication",
         "duration_minutes": 22, "sessions": 15, "first_used": "08:05", "last_used": "22:48"},
        {"name": "Safari", "bundle_id": "com.apple.mobilesafari", "category": "Browsing",
         "duration_minutes": 18, "sessions": 7, "first_used": "10:15", "last_used": "20:30"},
        {"name": "WeChat", "bundle_id": "com.tencent.xin", "category": "Communication",
         "duration_minutes": 15, "sessions": 9, "first_used": "08:30", "last_used": "22:00"},
        {"name": "Maps", "bundle_id": "com.apple.Maps", "category": "Navigation",
         "duration_minutes": 8, "sessions": 2, "first_used": "13:20", "last_used": "14:10"},
        {"name": "Camera", "bundle_id": "com.apple.camera", "category": "Utility",
         "duration_minutes": 5, "sessions": 3, "first_used": "11:45", "last_used": "17:22"},
        {"name": "Settings", "bundle_id": "com.apple.Preferences", "category": "Utility",
         "duration_minutes": 3, "sessions": 2, "first_used": "09:10", "last_used": "09:13"},
    ],
    "categories": {"Entertainment": 80, "Social": 28, "Communication": 37,
                   "Browsing": 18, "Navigation": 8, "Utility": 8},
}

MAC_DATA = {
    "date": TODAY,
    "total_active_minutes": 395,
    "deep_work_minutes": 175,
    "focus_score": 72,
    "context_switches": 34,
    "apps": [
        {"name": "Google Chrome", "bundle_id": "com.google.Chrome", "category": "Browsing",
         "duration_minutes": 120, "window_titles": ["Notion – feedling roadmap", "Linear – Sprint 3",
                                                      "Figma Community", "Stack Overflow"]},
        {"name": "Figma", "bundle_id": "com.figma.Desktop", "category": "Design",
         "duration_minutes": 95, "window_titles": ["Feedling iOS – v2 screens", "Component library"]},
        {"name": "Cursor", "bundle_id": "com.todesktop.230313mzl4w4u92", "category": "Development",
         "duration_minutes": 85, "window_titles": ["feedling-mcp-v1 – app.py", "feedling-mcp-v1 – SKILL.md"]},
        {"name": "Zoom", "bundle_id": "us.zoom.xos", "category": "Communication",
         "duration_minutes": 45, "window_titles": ["Weekly sync", "Design review"]},
        {"name": "Slack", "bundle_id": "com.tinyspeck.slackmacgap", "category": "Communication",
         "duration_minutes": 40, "window_titles": ["#design", "#eng", "#general", "DMs"]},
        {"name": "Terminal", "bundle_id": "com.apple.Terminal", "category": "Development",
         "duration_minutes": 10, "window_titles": ["zsh – feedling-mcp-v1"]},
    ],
    "categories": {"Browsing": 120, "Design": 95, "Development": 95, "Communication": 85},
}

SOURCES_DATA = {
    "sources": [
        {"id": "ios_pip", "name": "iPhone PIP Recording", "status": "connected",
         "last_sync": datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ"), "device": "iPhone 16 Pro"},
        {"id": "mac_monitor", "name": "Mac Screen Monitor", "status": "connected",
         "last_sync": datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ"), "device": "MacBook Pro M3"},
    ]
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.route("/v1/screen/ios", methods=["GET"])
def get_ios():
    return jsonify(IOS_DATA)


@app.route("/v1/screen/mac", methods=["GET"])
def get_mac():
    return jsonify(MAC_DATA)


@app.route("/v1/screen/summary", methods=["GET"])
def get_summary():
    summary = {
        "date": TODAY,
        "ios": {
            "total_screen_time_minutes": IOS_DATA["total_screen_time_minutes"],
            "top_app": IOS_DATA["apps"][0]["name"],
            "top_category": max(IOS_DATA["categories"], key=lambda k: IOS_DATA["categories"][k]),
            "pickups": IOS_DATA["pickups"],
        },
        "mac": {
            "total_active_minutes": MAC_DATA["total_active_minutes"],
            "deep_work_minutes": MAC_DATA["deep_work_minutes"],
            "focus_score": MAC_DATA["focus_score"],
            "top_app": MAC_DATA["apps"][0]["name"],
            "context_switches": MAC_DATA["context_switches"],
        },
        "combined": {
            "total_screen_minutes": IOS_DATA["total_screen_time_minutes"] + MAC_DATA["total_active_minutes"],
            "insight": "Heavy design + dev session on Mac. Phone usage mostly entertainment in evenings.",
        },
    }
    return jsonify(summary)


@app.route("/v1/sources", methods=["GET"])
def get_sources():
    return jsonify(SOURCES_DATA)


@app.route("/v1/push/dynamic-island", methods=["POST"])
def push_dynamic_island():
    """Alias for live-activity — Dynamic Island is driven by Live Activity pushes."""
    payload = request.get_json(silent=True) or {}
    return push_live_activity_inner(payload)


@app.route("/v1/push/live-activity", methods=["POST"])
def push_live_activity():
    payload = request.get_json(silent=True) or {}
    return push_live_activity_inner(payload)


def push_live_activity_inner(payload: dict):
    activity_id = payload.get("activity_id")
    entry = next(
        (t for t in REGISTERED_TOKENS
         if t["type"] in ("live-activity", "live_activity")
         and (not activity_id or t.get("activity_id") == activity_id)),
        None,
    )
    if not entry:
        print(f"[live-activity] no token registered — logged: {payload}")
        return jsonify({"status": "logged", "activity_id": activity_id or f"la_{uuid.uuid4().hex[:8]}"})

    apns_payload = {
        "aps": {
            "timestamp": int(time.time()),
            "event": payload.get("event", "update"),
            "content-state": {
                "topApp": payload.get("topApp", ""),
                "screenTimeMinutes": payload.get("screenTimeMinutes", 0),
                "message": payload.get("message", ""),
                "updatedAt": time.time(),
            },
            "alert": {"title": "", "body": ""},
        }
    }
    topic = f"{BUNDLE_ID}.push-type.liveactivity"
    result = _send_apns(entry["token"], apns_payload, push_type="liveactivity", topic=topic)
    if result.get("status") == "delivered":
        _record_successful_push()
        # Mirror to chat so user sees context when opening the app
        if apns_payload["aps"]["content-state"].get("message"):
            _append_chat("openclaw", apns_payload["aps"]["content-state"]["message"],
                         source="live_activity")
    print(f"[live-activity] {result}")
    return jsonify({"status": result["status"], "activity_id": activity_id})


@app.route("/v1/push/notification", methods=["POST"])
def push_notification():
    payload = request.get_json(silent=True) or {}
    device_token = next((t["token"] for t in REGISTERED_TOKENS if t["type"] == "apns"), None)
    if not device_token:
        print(f"[notification] no device token — logged: {payload}")
        return jsonify({"status": "logged", "message_id": f"msg_{uuid.uuid4().hex[:8]}"})

    apns_payload = {
        "aps": {
            "alert": {"title": payload.get("title", ""), "body": payload.get("body", "")},
            "sound": "default",
        }
    }
    result = _send_apns(device_token, apns_payload, push_type="alert", topic=BUNDLE_ID)
    print(f"[notification] {result}")
    return jsonify({"status": result["status"], "message_id": f"msg_{uuid.uuid4().hex[:8]}"})


@app.route("/v1/push/register-token", methods=["POST"])
def register_token():
    payload = request.get_json(silent=True) or {}
    token_type = payload.get("type", "unknown")
    token = payload.get("token", "")
    activity_id = payload.get("activity_id")

    entry = {"type": token_type, "token": token, "registered_at": datetime.now().isoformat()}
    if activity_id:
        entry["activity_id"] = activity_id

    # Keep latest per type (replace existing entry of same type/activity_id)
    REGISTERED_TOKENS[:] = [
        t for t in REGISTERED_TOKENS
        if not (t.get("type") == token_type and
                (not activity_id or t.get("activity_id") == activity_id))
    ]
    REGISTERED_TOKENS.append(entry)
    _save_tokens()

    print(f"[register-token] {token_type}: {token[:16]}…")
    return jsonify({"status": "registered", "type": token_type})


@app.route("/v1/push/tokens", methods=["GET"])
def list_tokens():
    return jsonify({"tokens": REGISTERED_TOKENS})


@app.route("/v1/screen/frames", methods=["GET"])
def list_frames():
    """List recent captured frames (metadata only)."""
    limit = min(int(request.args.get("limit", 20)), 100)
    with _frames_lock:
        recent = [f.copy() for f in reversed(_frames_meta)][:limit]
    for f in recent:
        f["url"] = _frame_url(f["filename"])
    return jsonify({"frames": recent, "total": len(_frames_meta)})


@app.route("/v1/screen/frames/latest", methods=["GET"])
def latest_frame():
    """Get the most recent frame with base64 image for OpenClaw to view."""
    with _frames_lock:
        if not _frames_meta:
            return jsonify({"error": "no frames yet"}), 404
        meta = _frames_meta[-1].copy()

    fpath = FRAMES_DIR / meta["filename"]
    if not fpath.exists():
        return jsonify({"error": "file missing"}), 404

    meta["image_base64"] = base64.b64encode(fpath.read_bytes()).decode()
    meta["url"] = _frame_url(meta["filename"])
    return jsonify(meta)


@app.route("/v1/screen/frames/<filename>", methods=["GET"])
def serve_frame(filename):
    fpath = FRAMES_DIR / filename
    if not fpath.exists():
        return jsonify({"error": "not found"}), 404
    return send_file(fpath, mimetype="image/jpeg")


@app.route("/v1/screen/analyze", methods=["GET"])
def analyze_screen():
    """
    Structured analysis of what the user is currently doing on their phone.
    Used by OpenClaw heartbeat to decide whether to push a Dynamic Island message.

    Query params:
      window_sec (int):           seconds of frame history to consider (default 300, clamped [30,3600])
      min_continuous_min (float): minimum continuous minutes on app to allow notify (default 3, clamped [1,120])
    """
    now = time.time()
    # P1: clamp parameters to safe ranges
    window_sec = max(30.0, min(3600.0, float(request.args.get("window_sec", 300))))
    min_continuous_min = max(1.0, min(120.0, float(request.args.get("min_continuous_min", 3))))

    with _frames_lock:
        recent = [f for f in _frames_meta if now - f["ts"] <= window_sec]

    if not recent:
        return jsonify({
            "active": False,
            "should_notify": False,
            "reason": "No frames in window — phone screen may be off or recording stopped.",
            "current_app": None,
            "continuous_minutes": 0,
            "ocr_summary": "",
            "cooldown_remaining_seconds": round(_cooldown_remaining_seconds()),
            "latest_ts": None,
            "frame_count_in_window": 0,
        })

    latest = recent[-1]
    current_app = latest.get("app") or "unknown"

    # Continuous time on current app.
    # Two safeguards:
    #   MAX_GAP_SECONDS: if adjacent frames are >8s apart, recording was interrupted — stop counting
    #   MAX_JITTER_FRAMES: up to 2 consecutive frames of a different app are tolerated (e.g. keyboard)
    MAX_GAP_SECONDS = 8
    MAX_JITTER_FRAMES = 2

    continuous_start_ts = latest["ts"]
    jitter_count = 0
    prev_ts = latest["ts"]

    for frame in reversed(recent[:-1]):
        # Gap check: break if recording was interrupted
        if prev_ts - frame["ts"] > MAX_GAP_SECONDS:
            break
        app = frame.get("app") or "unknown"
        if app == current_app:
            continuous_start_ts = frame["ts"]
            jitter_count = 0
        else:
            jitter_count += 1
            if jitter_count > MAX_JITTER_FRAMES:
                break
        prev_ts = frame["ts"]

    continuous_minutes = round((latest["ts"] - continuous_start_ts) / 60, 1)

    # OCR summary: last 3 non-empty, deduplicated, in chronological order
    seen_ocr: set[str] = set()
    ocr_parts: list[str] = []
    for f in reversed(recent):
        text = (f.get("ocr_text") or "").strip()
        if text and text not in seen_ocr:
            seen_ocr.add(text)
            ocr_parts.append(text[:200])
            if len(ocr_parts) >= 3:
                break
    ocr_summary = " | ".join(reversed(ocr_parts))[:500]

    # Determine should_notify and reason
    cooldown_remaining = _cooldown_remaining_seconds()

    if cooldown_remaining > 0:
        should_notify = False
        reason = f"cooldown: {round(cooldown_remaining)}s remaining"
    elif continuous_minutes < min_continuous_min:
        should_notify = False
        reason = f"continuous_minutes {continuous_minutes} < min_continuous_min {min_continuous_min}"
    else:
        should_notify = True
        reason = "ok"

    return jsonify({
        "active": True,
        "current_app": current_app,
        "continuous_minutes": continuous_minutes,
        "ocr_summary": ocr_summary,
        "should_notify": should_notify,
        "cooldown_remaining_seconds": round(cooldown_remaining),
        "reason": reason,
        "latest_ts": latest["ts"],
        "frame_count_in_window": len(recent),
    })


@app.route("/v1/chat/history", methods=["GET"])
def chat_history():
    """
    Get chat history.
    Query params:
      limit (int):   max messages to return (default 50, max 200)
      since (float): only return messages with ts > since (unix timestamp)
    """
    try:
        limit = int(request.args.get("limit", 50))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid limit"}), 400
    limit = max(1, min(limit, 200))

    try:
        since = float(request.args.get("since", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid since"}), 400

    with _chat_lock:
        msgs = [m for m in _chat_messages if m["ts"] > since]
        total = len(_chat_messages)
    msgs = msgs[-limit:]
    return jsonify({"messages": msgs, "total": total})


@app.route("/v1/chat/message", methods=["POST"])
def chat_message():
    """User sends a message to OpenClaw."""
    payload = request.get_json(silent=True) or {}
    content = (payload.get("content") or "").strip()
    if not content:
        return jsonify({"error": "content required"}), 400
    msg = _append_chat("user", content, source="chat")
    print(f"[chat] user: {content[:80]}")
    return jsonify({"id": msg["id"], "ts": msg["ts"]})


@app.route("/v1/chat/response", methods=["POST"])
def chat_response():
    """
    OpenClaw posts a chat response.
    Body: { "content": "...", "push_live_activity": false,
            "topApp": "...", "screenTimeMinutes": 0 }
    If push_live_activity is true, also triggers a Live Activity push.
    """
    payload = request.get_json(silent=True) or {}
    content = (payload.get("content") or "").strip()
    if not content:
        return jsonify({"error": "content required"}), 400

    msg = _append_chat("openclaw", content, source="chat")
    print(f"[chat] openclaw: {content[:80]}")

    if payload.get("push_live_activity"):
        push_payload = {
            "message": content,
            "topApp": payload.get("topApp", ""),
            "screenTimeMinutes": payload.get("screenTimeMinutes", 0),
        }
        push_live_activity_inner(push_payload)

    return jsonify({"id": msg["id"], "ts": msg["ts"]})


if __name__ == "__main__":
    print("Feedling server running at http://0.0.0.0:5001")
    app.run(host="0.0.0.0", port=5001, debug=False)
