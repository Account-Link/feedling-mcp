import asyncio
import base64
import errno
import json
import os
import threading
import time
import uuid
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import httpx
import jwt
import websockets
from flask import Flask, jsonify, request, send_file

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

FEEDLING_DIR = Path(os.environ.get("FEEDLING_DATA_DIR", str(Path.home() / "feedling-data"))).expanduser()
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
# Live Activity message dedupe state
# ---------------------------------------------------------------------------

LIVE_ACTIVITY_DEDUPE_SEC = int(os.environ.get("FEEDLING_LIVE_ACTIVITY_DEDUPE_SEC", 900))
LIVE_ACTIVITY_STATE_FILE = FEEDLING_DIR / "live_activity_state.json"
_live_activity_state_lock = threading.Lock()
_live_activity_state = {
    "last_message": "",
    "last_top_app": "",
    "last_sent_epoch": 0.0,
}


def _load_live_activity_state():
    global _live_activity_state
    try:
        if LIVE_ACTIVITY_STATE_FILE.exists():
            data = json.loads(LIVE_ACTIVITY_STATE_FILE.read_text())
            if isinstance(data, dict):
                _live_activity_state = {
                    "last_message": str(data.get("last_message", "")),
                    "last_top_app": str(data.get("last_top_app", "")),
                    "last_sent_epoch": float(data.get("last_sent_epoch", 0.0)),
                }
    except Exception as e:
        print(f"[live-activity] failed to load dedupe state: {e}")


def _save_live_activity_state():
    try:
        LIVE_ACTIVITY_STATE_FILE.write_text(json.dumps(_live_activity_state))
    except Exception as e:
        print(f"[live-activity] failed to save dedupe state: {e}")


def _should_suppress_live_activity(message: str, top_app: str) -> tuple[bool, str]:
    normalized_message = " ".join((message or "").strip().split())
    normalized_app = (top_app or "").strip().lower()
    if not normalized_message:
        return True, "empty_message"

    with _live_activity_state_lock:
        last_message = " ".join((_live_activity_state.get("last_message") or "").strip().split())
        last_app = (_live_activity_state.get("last_top_app") or "").strip().lower()
        last_sent = float(_live_activity_state.get("last_sent_epoch", 0.0))

    elapsed = max(0.0, time.time() - last_sent)

    # Suppress exact same wording for 30 minutes.
    if normalized_message == last_message and elapsed < 1800:
        return True, f"duplicate_message_within_30m:{int(1800 - elapsed)}s"

    # Suppress same app + same wording bursts in shorter dedupe window.
    if normalized_message == last_message and normalized_app == last_app and elapsed < LIVE_ACTIVITY_DEDUPE_SEC:
        return True, f"same_app_duplicate:{int(LIVE_ACTIVITY_DEDUPE_SEC - elapsed)}s"

    return False, "ok"


def _record_live_activity_sent(message: str, top_app: str):
    with _live_activity_state_lock:
        _live_activity_state["last_message"] = " ".join((message or "").strip().split())
        _live_activity_state["last_top_app"] = (top_app or "").strip().lower()
        _live_activity_state["last_sent_epoch"] = time.time()
    _save_live_activity_state()


_load_live_activity_state()

# ---------------------------------------------------------------------------
# Semantic-first trigger helpers
# ---------------------------------------------------------------------------


def _contains_any(text: str, keywords: tuple[str, ...]) -> bool:
    t = (text or "").lower()
    return any(k in t for k in keywords)


def _semantic_analysis(current_app: str, ocr_summary: str) -> dict:
    """
    Semantic-first screen interpretation.
    Behavior metrics (dwell/switch) are secondary confidence signals only.
    """
    app = (current_app or "unknown").lower()
    text = (ocr_summary or "").lower()

    ecom_apps = ("taobao", "tmall", "jd", "pinduoduo", "xhs", "red", "amazon", "shop")
    compare_words = (
        "加入购物车", "购物车", "比价", "对比", "参数", "评价", "评论", "销量", "券", "优惠", "选哪个", "纠结", "尺码", "颜色",
        "cart", "review", "compare", "coupon", "which one", "size", "color",
    )
    chat_apps = ("wechat", "telegram", "whatsapp", "messenger", "imessage", "discord", "slack")
    chat_words = (
        "输入", "正在输入", "撤回", "删了", "草稿", "怎么回", "回什么", "算了", "生气", "误会", "抱歉", "对不起", "别这样", "随便",
        "typing", "draft", "unsent", "sorry", "angry", "misunderstand",
    )

    if (_contains_any(app, ecom_apps) or _contains_any(text, ecom_apps)) and _contains_any(text, compare_words):
        return {
            "semantic_scene": "ecommerce_choice_paralysis",
            "task_intent": "compare_then_decide",
            "friction_point": "choice_overload",
            "semantic_strength": "strong",
            "confidence": 0.86,
            "suggested_openers": [
                "你像在 A/B 里卡住了：你更在意省钱，还是少踩雷？",
                "先别全看，我帮你偷懒：差评关键词 + 近30天销量 + 退货评价，三项就够定。",
                "给你一个止损线：再看 5 分钟就选一个，剩下放收藏。",
            ],
        }

    if (_contains_any(app, chat_apps) or _contains_any(text, chat_apps)) and _contains_any(text, chat_words):
        return {
            "semantic_scene": "social_chat_hesitation",
            "task_intent": "draft_or_repair_message",
            "friction_point": "hesitation_or_conflict",
            "semantic_strength": "strong",
            "confidence": 0.83,
            "suggested_openers": [
                "这句你更想保住关系，还是讲清立场？我给你两版一句话。",
                "你像在反复删改。先发降温版一句话，别让情绪抬高。",
                "要硬一点还是软一点？我各给一版，10 秒选。",
            ],
        }

    # Ambiguous context: still allow gentle, curiosity-first conversation starts.
    return {
        "semantic_scene": "ambiguous_context",
        "task_intent": "unknown",
        "friction_point": "unclear_state",
        "semantic_strength": "weak",
        "confidence": 0.38,
        "suggested_openers": [
            "我可能看错了，这会儿你是在想事，还是在躲这件事？",
            "我没完全读懂这屏，但感觉你有点绷着。要我陪你理一下吗？",
            "你现在更需要：被提醒一下，还是被安静陪着？",
        ],
    }


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


def _normalize_token_entry(entry: dict) -> dict:
    """Backfill lifecycle fields for legacy token rows."""
    normalized = dict(entry)
    normalized.setdefault("status", "active")
    normalized.setdefault("last_error", "")
    normalized.setdefault("last_success_at", "")
    normalized.setdefault("updated_at", normalized.get("registered_at", datetime.now().isoformat()))
    return normalized


def _is_live_activity_token(entry: dict) -> bool:
    return entry.get("type") in ("live-activity", "live_activity")


def _is_push_to_start_token(entry: dict) -> bool:
    return entry.get("type") == "push_to_start"


def _entry_is_active(entry: dict) -> bool:
    return (entry.get("status") or "active") == "active"


def _select_token(predicate, activity_id: str | None = None, active_only: bool = True):
    candidates = []
    for raw in REGISTERED_TOKENS:
        entry = _normalize_token_entry(raw)
        if not predicate(entry):
            continue
        if activity_id and entry.get("activity_id") != activity_id:
            continue
        if active_only and not _entry_is_active(entry):
            continue
        if not entry.get("token"):
            continue
        candidates.append(entry)

    if not candidates:
        return None

    # Newest token wins.
    candidates.sort(key=lambda x: x.get("registered_at", ""), reverse=True)
    return candidates[0]


def _update_token_lifecycle(entry: dict, *, status: str | None = None, last_error: str | None = None, success: bool = False):
    token = entry.get("token")
    token_type = entry.get("type")
    activity_id = entry.get("activity_id")
    now_iso = datetime.now().isoformat()

    changed = False
    for idx, raw in enumerate(REGISTERED_TOKENS):
        cur = _normalize_token_entry(raw)
        if cur.get("token") != token or cur.get("type") != token_type or cur.get("activity_id") != activity_id:
            continue
        if status is not None:
            cur["status"] = status
        if last_error is not None:
            cur["last_error"] = last_error
        if success:
            cur["last_success_at"] = now_iso
            cur["status"] = "active"
            cur["last_error"] = ""
        cur["updated_at"] = now_iso
        REGISTERED_TOKENS[idx] = cur
        changed = True
        break

    if changed:
        _save_tokens()


def _mark_expired_token(entry: dict, reason: str):
    _update_token_lifecycle(entry, status="expired", last_error=reason)


def _mark_active_token_success(entry: dict):
    _update_token_lifecycle(entry, success=True)


_load_tokens()
# Backfill lifecycle fields for tokens persisted before lifecycle metadata existed.
REGISTERED_TOKENS[:] = [_normalize_token_entry(t) for t in REGISTERED_TOKENS]
_save_tokens()

# ---------------------------------------------------------------------------
# Chat history (persistent)
# ---------------------------------------------------------------------------

CHAT_FILE = FEEDLING_DIR / "chat.json"
MAX_CHAT_MESSAGES = 500

_chat_messages: list[dict] = []
_chat_lock = threading.Lock()

# Long-poll waiters: list of threading.Event, one per waiting request
_chat_waiters: list[threading.Event] = []
_chat_waiters_lock = threading.Lock()


def _notify_chat_waiters():
    """Wake up all long-poll waiters when a new user message arrives."""
    with _chat_waiters_lock:
        for ev in _chat_waiters:
            ev.set()
        _chat_waiters.clear()


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
# Data models / aggregation
# ---------------------------------------------------------------------------

TODAY = datetime.now().strftime("%Y-%m-%d")

IOS_FALLBACK_DATA = {
    "date": TODAY,
    "total_screen_time_minutes": 0,
    "scroll_distance_meters": 0.0,
    "pickups": 0,
    "unlock_count": 0,
    "apps": [],
    "categories": {},
    "frame_count": 0,
    "data_source": "mock_fallback",
}


def _humanize_app_name(raw: str) -> str:
    value = (raw or "unknown").strip()
    if not value:
        return "Unknown"
    if value.startswith("com."):
        tail = value.split(".")[-1]
        if not tail:
            return value
        return tail.replace("_", " ").replace("-", " ").title()
    return value


def _category_for_app(app_name_or_bundle: str) -> str:
    key = (app_name_or_bundle or "").lower()
    if any(x in key for x in ["tiktok", "youtube", "bili", "netflix"]):
        return "Entertainment"
    if any(x in key for x in ["instagram", "twitter", "x.com", "xiaohong", "reddit"]):
        return "Social"
    if any(x in key for x in ["wechat", "telegram", "whatsapp", "messages", "slack", "feishu", "lark"]):
        return "Communication"
    if any(x in key for x in ["safari", "chrome", "browser"]):
        return "Browsing"
    if any(x in key for x in ["maps", "map", "gaode", "waze"]):
        return "Navigation"
    if any(x in key for x in ["camera", "photos", "settings", "preference", "clock", "calendar"]):
        return "Utility"
    return "Other"


def _to_hhmm(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%H:%M")


def _build_ios_data(window_sec: float = 86400.0) -> dict:
    now = time.time()
    with _frames_lock:
        frames = [f.copy() for f in _frames_meta if now - float(f.get("ts", 0)) <= window_sec]

    if not frames:
        fallback = IOS_FALLBACK_DATA.copy()
        fallback["date"] = datetime.now().strftime("%Y-%m-%d")
        return fallback

    frames.sort(key=lambda f: float(f.get("ts", 0)))

    per_app = defaultdict(lambda: {
        "name": "Unknown",
        "bundle_id": "",
        "category": "Other",
        "duration_seconds": 0.0,
        "sessions": 0,
        "first_ts": 0.0,
        "last_ts": 0.0,
    })
    categories_seconds = defaultdict(float)

    MAX_STEP_SECONDS = 8.0
    NEW_SESSION_GAP_SECONDS = 45.0

    session_count = 0
    prev_app_key = None
    prev_ts = None

    for i, frame in enumerate(frames):
        ts = float(frame.get("ts", 0.0))
        app_raw = frame.get("app") or "unknown"
        app_key = str(app_raw)

        row = per_app[app_key]
        row["name"] = _humanize_app_name(app_key)
        row["bundle_id"] = app_key
        row["category"] = _category_for_app(app_key)
        row["last_ts"] = ts
        if not row["first_ts"]:
            row["first_ts"] = ts

        if prev_ts is None:
            session_count += 1
            row["sessions"] += 1
        else:
            gap = max(0.0, ts - prev_ts)
            if app_key != prev_app_key or gap > NEW_SESSION_GAP_SECONDS:
                session_count += 1
                row["sessions"] += 1

            if prev_app_key is not None:
                step = min(gap, MAX_STEP_SECONDS)
                per_app[prev_app_key]["duration_seconds"] += step
                categories_seconds[per_app[prev_app_key]["category"]] += step

        prev_app_key = app_key
        prev_ts = ts

    if prev_app_key is not None:
        per_app[prev_app_key]["duration_seconds"] += 1.0
        categories_seconds[per_app[prev_app_key]["category"]] += 1.0

    apps = []
    total_seconds = 0.0
    for app_key, row in per_app.items():
        dur_min = round(row["duration_seconds"] / 60.0, 1)
        total_seconds += row["duration_seconds"]
        apps.append({
            "name": row["name"],
            "bundle_id": row["bundle_id"],
            "category": row["category"],
            "duration_minutes": dur_min,
            "sessions": int(row["sessions"]),
            "first_used": _to_hhmm(row["first_ts"]),
            "last_used": _to_hhmm(row["last_ts"]),
        })

    apps.sort(key=lambda a: a["duration_minutes"], reverse=True)

    categories = {
        cat: round(sec / 60.0, 1)
        for cat, sec in sorted(categories_seconds.items(), key=lambda kv: kv[1], reverse=True)
        if sec > 0
    }

    total_minutes = round(total_seconds / 60.0, 1)
    return {
        "date": datetime.now().strftime("%Y-%m-%d"),
        "total_screen_time_minutes": total_minutes,
        "scroll_distance_meters": round(total_minutes * 0.02, 2),
        "pickups": int(session_count),
        "unlock_count": int(session_count),
        "apps": apps,
        "categories": categories,
        "frame_count": len(frames),
        "window_sec": int(window_sec),
        "data_source": "real_frames",
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
    """iOS usage aggregated from real frame stream in the selected window."""
    try:
        window_sec = max(300.0, min(172800.0, float(request.args.get("window_sec", 86400))))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid window_sec"}), 400
    return jsonify(_build_ios_data(window_sec=window_sec))


@app.route("/v1/screen/mac", methods=["GET"])
def get_mac():
    return jsonify(MAC_DATA)


@app.route("/v1/screen/summary", methods=["GET"])
def get_summary():
    ios_data = _build_ios_data(window_sec=86400)
    top_app = ios_data["apps"][0]["name"] if ios_data.get("apps") else "Unknown"
    categories = ios_data.get("categories") or {}
    top_category = max(categories, key=categories.get) if categories else "Other"

    summary = {
        "date": datetime.now().strftime("%Y-%m-%d"),
        "ios": {
            "total_screen_time_minutes": ios_data.get("total_screen_time_minutes", 0),
            "top_app": top_app,
            "top_category": top_category,
            "pickups": ios_data.get("pickups", 0),
            "data_source": ios_data.get("data_source", "unknown"),
            "frame_count": ios_data.get("frame_count", 0),
        },
        "mac": {
            "total_active_minutes": MAC_DATA["total_active_minutes"],
            "deep_work_minutes": MAC_DATA["deep_work_minutes"],
            "focus_score": MAC_DATA["focus_score"],
            "top_app": MAC_DATA["apps"][0]["name"],
            "context_switches": MAC_DATA["context_switches"],
        },
        "combined": {
            "total_screen_minutes": ios_data.get("total_screen_time_minutes", 0) + MAC_DATA["total_active_minutes"],
            "insight": "Phone side now comes from real frame aggregation; Mac remains mocked.",
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
    entry = _select_token(_is_live_activity_token, activity_id=activity_id, active_only=True)
    if not entry and activity_id:
        # Caller may pass a stale activity_id; try newest active token as fallback.
        entry = _select_token(_is_live_activity_token, activity_id=None, active_only=True)

    if not entry:
        print(f"[live-activity] no active token registered — logged: {payload}")
        return jsonify({
            "status": "logged",
            "activity_id": activity_id or f"la_{uuid.uuid4().hex[:8]}",
            "needs_refresh": True,
            "reason": "no_active_live_activity_token",
        })

    message = (payload.get("message") or "").strip()
    top_app = payload.get("topApp", "")

    suppress, reason = _should_suppress_live_activity(message=message, top_app=top_app)
    if suppress:
        print(f"[live-activity] suppressed: {reason} message={message[:60]}")
        return jsonify({"status": "suppressed", "reason": reason, "activity_id": entry.get("activity_id")})

    apns_payload = {
        "aps": {
            "timestamp": int(time.time()),
            "event": payload.get("event", "update"),
            "content-state": {
                "topApp": top_app,
                "screenTimeMinutes": payload.get("screenTimeMinutes", 0),
                "message": message,
                "updatedAt": time.time(),
            },
            "alert": {"title": "", "body": ""},
        }
    }
    topic = f"{BUNDLE_ID}.push-type.liveactivity"
    result = _send_apns(entry["token"], apns_payload, push_type="liveactivity", topic=topic)

    delivered = result.get("status") == "delivered"
    if delivered:
        _mark_active_token_success(entry)
        _record_successful_push()
        _record_live_activity_sent(message=message, top_app=top_app)
        # Mirror to chat so user sees context when opening the app
        if message:
            _append_chat("openclaw", message, source="live_activity")
    else:
        reason = str(result.get("reason", ""))
        error_code = result.get("code")
        if error_code == 410 and ("ExpiredToken" in reason or "Unregistered" in reason):
            _mark_expired_token(entry, reason)
            print(f"[live-activity] token expired, marked inactive: activity_id={entry.get('activity_id')}")

    print(f"[live-activity] {result}")
    response = {
        "status": result.get("status", "error"),
        "activity_id": entry.get("activity_id") or activity_id,
    }
    if result.get("code") is not None:
        response["error_code"] = result.get("code")
    if result.get("reason"):
        response["reason"] = result.get("reason")
    if result.get("code") == 410:
        response["needs_refresh"] = True
    return jsonify(response)


@app.route("/v1/push/live-start", methods=["POST"])
def push_live_start():
    """
    Send a push-to-start event so iOS can (re)start Live Activity and upload a fresh live_activity token.
    """
    payload = request.get_json(silent=True) or {}
    entry = _select_token(_is_push_to_start_token, active_only=True)
    if not entry:
        print(f"[live-start] no push_to_start token — logged: {payload}")
        return jsonify({"status": "logged", "reason": "no_active_push_to_start_token"})

    message = (payload.get("message") or "").strip()
    top_app = payload.get("topApp", "")
    apns_payload = {
        "aps": {
            "timestamp": int(time.time()),
            "event": "start",
            "content-state": {
                "topApp": top_app,
                "screenTimeMinutes": payload.get("screenTimeMinutes", 0),
                "message": message,
                "updatedAt": time.time(),
            },
            "alert": {"title": "", "body": ""},
        }
    }

    topic = f"{BUNDLE_ID}.push-type.liveactivity"
    result = _send_apns(entry["token"], apns_payload, push_type="liveactivity", topic=topic)
    if result.get("status") == "delivered":
        _mark_active_token_success(entry)
    else:
        reason = str(result.get("reason", ""))
        error_code = result.get("code")
        if error_code == 410 and ("ExpiredToken" in reason or "Unregistered" in reason):
            _mark_expired_token(entry, reason)

    print(f"[live-start] {result}")
    response = {"status": result.get("status", "error")}
    if result.get("code") is not None:
        response["error_code"] = result.get("code")
    if result.get("reason"):
        response["reason"] = result.get("reason")
    return jsonify(response)


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

    now_iso = datetime.now().isoformat()
    entry = {
        "type": token_type,
        "token": token,
        "registered_at": now_iso,
        "status": "active",
        "last_error": "",
        "last_success_at": "",
        "updated_at": now_iso,
    }
    if activity_id:
        entry["activity_id"] = activity_id

    # Keep latest per type/activity_id or same exact token.
    REGISTERED_TOKENS[:] = [
        _normalize_token_entry(t)
        for t in REGISTERED_TOKENS
        if not (
            t.get("token") == token
            or (
                t.get("type") == token_type
                and (not activity_id or t.get("activity_id") == activity_id)
            )
        )
    ]
    REGISTERED_TOKENS.append(entry)
    _save_tokens()

    print(f"[register-token] {token_type}: {token[:16]}…")
    return jsonify({"status": "registered", "type": token_type})


@app.route("/v1/push/tokens", methods=["GET"])
def list_tokens():
    active_only = request.args.get("active_only", "false").lower() == "true"
    tokens = [_normalize_token_entry(t) for t in REGISTERED_TOKENS]
    if active_only:
        tokens = [t for t in tokens if _entry_is_active(t)]
    return jsonify({"tokens": tokens})


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
            "latest_frame_filename": None,
            "latest_frame_url": None,
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

    # Semantic-first trigger decision (behavior metrics are secondary)
    cooldown_remaining = _cooldown_remaining_seconds()
    semantic = _semantic_analysis(current_app=current_app, ocr_summary=ocr_summary)
    semantic_strength = semantic.get("semantic_strength", "weak")

    # Allow curiosity-first openers in ambiguous contexts if we have enough on-screen text.
    exploratory_allowed = (
        semantic_strength == "weak"
        and len(ocr_summary) >= 20
        and continuous_minutes >= 1.0
    )

    if cooldown_remaining > 0:
        should_notify = False
        trigger_basis = "cooldown"
        reason = f"cooldown: {round(cooldown_remaining)}s remaining"
    elif semantic_strength == "strong":
        should_notify = True
        trigger_basis = "semantic_strong"
        reason = f"semantic:{semantic.get('semantic_scene', 'unknown')}"
    elif exploratory_allowed:
        should_notify = True
        trigger_basis = "curiosity_exploratory"
        reason = "ambiguous_context_but_conversation_worth_starting"
    elif continuous_minutes >= min_continuous_min:
        # Legacy fallback for compatibility with existing callers.
        should_notify = True
        trigger_basis = "legacy_time_fallback"
        reason = f"continuous_minutes {continuous_minutes} >= min_continuous_min {min_continuous_min}"
    else:
        should_notify = False
        trigger_basis = "insufficient_signal"
        reason = "no_semantic_trigger_and_not_enough_context"

    return jsonify({
        "active": True,
        "current_app": current_app,
        "continuous_minutes": continuous_minutes,
        "ocr_summary": ocr_summary,
        "should_notify": should_notify,
        "cooldown_remaining_seconds": round(cooldown_remaining),
        "reason": reason,
        "trigger_policy": "semantic_first",
        "trigger_basis": trigger_basis,
        "semantic_scene": semantic.get("semantic_scene"),
        "task_intent": semantic.get("task_intent"),
        "friction_point": semantic.get("friction_point"),
        "semantic_confidence": semantic.get("confidence", 0.0),
        "suggested_openers": semantic.get("suggested_openers", [])[:2],
        "latest_ts": latest["ts"],
        "latest_frame_filename": latest.get("filename"),
        "latest_frame_url": _frame_url(latest.get("filename")) if latest.get("filename") else None,
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
        # Default to a larger window so iOS clients calling /v1/chat/history?since=0
        # can recover full recent history after reconnect/restart.
        limit = int(request.args.get("limit", 200))
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

    # Add compatibility aliases for mixed iOS client builds.
    out = []
    for m in msgs:
        item = dict(m)
        role = item.get("role")
        if role == "openclaw":
            item["sender"] = "assistant"   # legacy alias
            item["is_from_openclaw"] = True
        elif role == "user":
            item["sender"] = "user"
            item["is_from_openclaw"] = False
        out.append(item)

    ua = request.headers.get("User-Agent", "")
    print(f"[chat/history] ip={request.remote_addr} since={since} limit={limit} returned={len(out)} total={total} ua={ua[:120]}")

    return jsonify({"messages": out, "total": total})


@app.route("/v1/chat/message", methods=["POST"])
def chat_message():
    """User sends a message to OpenClaw."""
    payload = request.get_json(silent=True) or {}
    content = (payload.get("content") or "").strip()
    if not content:
        return jsonify({"error": "content required"}), 400
    msg = _append_chat("user", content, source="chat")
    _notify_chat_waiters()
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


@app.route("/v1/chat/poll", methods=["GET"])
def chat_poll():
    """
    Long-poll endpoint for OpenClaw. Hangs until a new user message arrives or timeout.

    Query params:
      since   (float): only return messages with ts > since (default 0)
      timeout (float): max seconds to wait (default 30, max 60)

    Response:
      { "messages": [...], "timed_out": false }  — new user message(s) arrived
      { "messages": [],    "timed_out": true  }  — no message within timeout; do screen check
    """
    try:
        since = float(request.args.get("since", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid since"}), 400
    timeout = min(float(request.args.get("timeout", 30)), 60)

    # Check for already-pending user messages before blocking
    with _chat_lock:
        pending = [m for m in _chat_messages if m["ts"] > since and m["role"] == "user"]
    if pending:
        return jsonify({"messages": pending, "timed_out": False})

    # Register a waiter and block
    ev = threading.Event()
    with _chat_waiters_lock:
        _chat_waiters.append(ev)

    notified = ev.wait(timeout=timeout)

    with _chat_waiters_lock:
        try:
            _chat_waiters.remove(ev)
        except ValueError:
            pass

    if notified:
        with _chat_lock:
            pending = [m for m in _chat_messages if m["ts"] > since and m["role"] == "user"]
        return jsonify({"messages": pending, "timed_out": False})
    else:
        return jsonify({"messages": [], "timed_out": True})


if __name__ == "__main__":
    print("Feedling server running at http://0.0.0.0:5001")
    app.run(host="0.0.0.0", port=5001, debug=False)
