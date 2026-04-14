import asyncio
import base64
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
# Frames storage
# ---------------------------------------------------------------------------

FRAMES_DIR = Path.home() / "feedling" / "frames"
FRAMES_DIR.mkdir(parents=True, exist_ok=True)
MAX_FRAMES = 200  # keep last 200 frames on disk

_frames_meta: list[dict] = []  # in-memory index: [{filename, ts, app, ocr_text, w, h}]
_frames_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Push cooldown state (thread-safe + persistent)
# ---------------------------------------------------------------------------

PUSH_COOLDOWN_SECONDS = int(os.environ.get("FEEDLING_PUSH_COOLDOWN_SEC", 300))
PUSH_STATE_FILE = Path.home() / "feedling" / "push_state.json"

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
                # Cooldown still active — reconstruct monotonic offset
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
        # trim in-memory index
        if len(_frames_meta) > MAX_FRAMES:
            removed = _frames_meta.pop(0)
            old = FRAMES_DIR / removed["filename"]
            if old.exists():
                old.unlink()

    print(f"[ingest] saved {filename} app={meta['app']} ocr={len(meta['ocr_text'])}chars")


# ---------------------------------------------------------------------------
# WebSocket ingest server (port 9999)
# ---------------------------------------------------------------------------

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
    print(f"[ws] client disconnected")


def _run_ws_server():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    server = loop.run_until_complete(
        websockets.serve(_ws_handler, "0.0.0.0", 9998)
    )
    print("[ws] WebSocket ingest server running on ws://0.0.0.0:9998/ingest")
    loop.run_forever()


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
    Path.home() / "feedling" / f"AuthKey_{KEY_ID}.p8",
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
        {
            "name": "TikTok",
            "bundle_id": "com.zhiliaoapp.musically",
            "category": "Entertainment",
            "duration_minutes": 45,
            "sessions": 6,
            "first_used": "08:14",
            "last_used": "22:31",
        },
        {
            "name": "YouTube",
            "bundle_id": "com.google.ios.youtube",
            "category": "Entertainment",
            "duration_minutes": 35,
            "sessions": 4,
            "first_used": "12:02",
            "last_used": "21:45",
        },
        {
            "name": "Instagram",
            "bundle_id": "com.burbn.instagram",
            "category": "Social",
            "duration_minutes": 28,
            "sessions": 8,
            "first_used": "09:30",
            "last_used": "22:10",
        },
        {
            "name": "Messages",
            "bundle_id": "com.apple.MobileSMS",
            "category": "Communication",
            "duration_minutes": 22,
            "sessions": 15,
            "first_used": "08:05",
            "last_used": "22:48",
        },
        {
            "name": "Safari",
            "bundle_id": "com.apple.mobilesafari",
            "category": "Browsing",
            "duration_minutes": 18,
            "sessions": 7,
            "first_used": "10:15",
            "last_used": "20:30",
        },
        {
            "name": "WeChat",
            "bundle_id": "com.tencent.xin",
            "category": "Communication",
            "duration_minutes": 15,
            "sessions": 9,
            "first_used": "08:30",
            "last_used": "22:00",
        },
        {
            "name": "Maps",
            "bundle_id": "com.apple.Maps",
            "category": "Navigation",
            "duration_minutes": 8,
            "sessions": 2,
            "first_used": "13:20",
            "last_used": "14:10",
        },
        {
            "name": "Camera",
            "bundle_id": "com.apple.camera",
            "category": "Utility",
            "duration_minutes": 5,
            "sessions": 3,
            "first_used": "11:45",
            "last_used": "17:22",
        },
        {
            "name": "Settings",
            "bundle_id": "com.apple.Preferences",
            "category": "Utility",
            "duration_minutes": 3,
            "sessions": 2,
            "first_used": "09:10",
            "last_used": "09:13",
        },
    ],
    "categories": {
        "Entertainment": 80,
        "Social": 28,
        "Communication": 37,
        "Browsing": 18,
        "Navigation": 8,
        "Utility": 8,
    },
}

MAC_DATA = {
    "date": TODAY,
    "total_active_minutes": 395,
    "deep_work_minutes": 175,
    "focus_score": 72,
    "context_switches": 34,
    "apps": [
        {
            "name": "Google Chrome",
            "bundle_id": "com.google.Chrome",
            "category": "Browsing",
            "duration_minutes": 120,
            "window_titles": [
                "Notion – feedling roadmap",
                "Linear – Sprint 3",
                "Figma Community",
                "Stack Overflow",
            ],
        },
        {
            "name": "Figma",
            "bundle_id": "com.figma.Desktop",
            "category": "Design",
            "duration_minutes": 95,
            "window_titles": [
                "Feedling iOS – v2 screens",
                "Component library",
                "Onboarding flow",
            ],
        },
        {
            "name": "Cursor",
            "bundle_id": "com.todesktop.230313mzl4w4u92",
            "category": "Development",
            "duration_minutes": 85,
            "window_titles": [
                "feedling-mcp-v1 – app.py",
                "feedling-ios – LiveActivity.swift",
                "feedling-mcp-v1 – SKILL.md",
            ],
        },
        {
            "name": "Zoom",
            "bundle_id": "us.zoom.xos",
            "category": "Communication",
            "duration_minutes": 45,
            "window_titles": ["Weekly sync", "Design review"],
        },
        {
            "name": "Slack",
            "bundle_id": "com.tinyspeck.slackmacgap",
            "category": "Communication",
            "duration_minutes": 40,
            "window_titles": ["#design", "#eng", "#general", "DMs"],
        },
        {
            "name": "Terminal",
            "bundle_id": "com.apple.Terminal",
            "category": "Development",
            "duration_minutes": 10,
            "window_titles": ["zsh – feedling-mcp-v1"],
        },
    ],
    "categories": {
        "Browsing": 120,
        "Design": 95,
        "Development": 95,
        "Communication": 85,
    },
}

SOURCES_DATA = {
    "sources": [
        {
            "id": "ios_pip",
            "name": "iPhone PIP Recording",
            "status": "connected",
            "last_sync": datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "device": "iPhone 16 Pro",
        },
        {
            "id": "mac_monitor",
            "name": "Mac Screen Monitor",
            "status": "connected",
            "last_sync": datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "device": "MacBook Pro M3",
        },
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
            "top_category": max(
                IOS_DATA["categories"], key=lambda k: IOS_DATA["categories"][k]
            ),
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
            "total_screen_minutes": IOS_DATA["total_screen_time_minutes"]
            + MAC_DATA["total_active_minutes"],
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

    top_app = payload.get("topApp", "")
    minutes = payload.get("screenTimeMinutes", 0)
    message = payload.get("message", "")
    apns_payload = {
        "aps": {
            "timestamp": int(time.time()),
            "event": payload.get("event", "update"),
            "content-state": {
                "topApp": top_app,
                "screenTimeMinutes": minutes,
                "message": message,
                "updatedAt": time.time(),
            },
            "alert": {"title": "", "body": ""},
        }
    }
    topic = f"{BUNDLE_ID}.push-type.liveactivity"
    result = _send_apns(entry["token"], apns_payload, push_type="liveactivity", topic=topic)
    if result.get("status") == "delivered":
        _record_successful_push()
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
    msg_id = f"msg_{uuid.uuid4().hex[:8]}"
    print(f"[notification] {result}")
    return jsonify({"status": result["status"], "message_id": msg_id})


# In-memory store for push tokens (mock — no real APNs yet)
REGISTERED_TOKENS: list[dict] = []


@app.route("/v1/push/register-token", methods=["POST"])
def register_token():
    payload = request.get_json(silent=True) or {}
    token_type = payload.get("type", "unknown")
    token = payload.get("token", "")
    activity_id = payload.get("activity_id")

    entry = {"type": token_type, "token": token, "registered_at": datetime.now().isoformat()}
    if activity_id:
        entry["activity_id"] = activity_id

    # Keep latest per type
    REGISTERED_TOKENS[:] = [t for t in REGISTERED_TOKENS if t.get("type") != token_type or
                             (activity_id and t.get("activity_id") != activity_id)]
    REGISTERED_TOKENS.append(entry)

    print(f"[register-token] {token_type}: {token[:16]}…")
    return jsonify({"status": "registered", "type": token_type})


@app.route("/v1/push/tokens", methods=["GET"])
def list_tokens():
    """Debug endpoint — shows all registered push tokens."""
    return jsonify({"tokens": REGISTERED_TOKENS})


@app.route("/v1/screen/frames", methods=["GET"])
def list_frames():
    """List recent captured frames (metadata only)."""
    limit = min(int(request.args.get("limit", 20)), 100)
    with _frames_lock:
        recent = list(reversed(_frames_meta))[:limit]
    for f in recent:
        f["url"] = f"http://54.209.126.4:5001/v1/screen/frames/{f['filename']}"
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

    img_b64 = base64.b64encode(fpath.read_bytes()).decode()
    meta["image_base64"] = img_b64
    meta["url"] = f"http://54.209.126.4:5001/v1/screen/frames/{meta['filename']}"
    return jsonify(meta)


@app.route("/v1/screen/frames/<filename>", methods=["GET"])
def serve_frame(filename):
    """Serve a frame image file."""
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
      window_sec (int):         seconds of frame history to consider (default 300)
      min_continuous_min (float): minimum continuous minutes on app to allow notify (default 3)
    """
    now = time.time()
    window_sec = float(request.args.get("window_sec", 300))
    min_continuous_min = float(request.args.get("min_continuous_min", 3))

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

    # Continuous time on current app, with jitter tolerance.
    # Up to MAX_JITTER_FRAMES consecutive frames of a different app are ignored
    # (e.g. a system alert or keyboard briefly covering the screen).
    MAX_JITTER_FRAMES = 2
    continuous_start_ts = latest["ts"]
    jitter_count = 0
    for frame in reversed(recent[:-1]):
        app = frame.get("app") or "unknown"
        if app == current_app:
            continuous_start_ts = frame["ts"]
            jitter_count = 0
        else:
            jitter_count += 1
            if jitter_count > MAX_JITTER_FRAMES:
                break

    continuous_minutes = round((latest["ts"] - continuous_start_ts) / 60, 1)

    # OCR summary: last 3 non-empty, deduplicated, newest-first then reversed to chron order
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

    # Cooldown + min_continuous_min checks → should_notify + reason
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


if __name__ == "__main__":
    print("Feedling mock server running at http://localhost:5001")
    app.run(host="0.0.0.0", port=5001, debug=True)
