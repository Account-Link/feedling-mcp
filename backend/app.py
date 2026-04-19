import asyncio
import base64
import errno
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
import uuid
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import httpx
import jwt
import websockets
from flask import Flask, abort, g, jsonify, request, send_file

# ---------------------------------------------------------------------------
# Root directory + deployment mode
# ---------------------------------------------------------------------------

FEEDLING_DIR = Path(os.environ.get("FEEDLING_DATA_DIR", str(Path.home() / "feedling-data"))).expanduser()
FEEDLING_DIR.mkdir(parents=True, exist_ok=True)

# SINGLE_USER=true  → flat layout in FEEDLING_DIR, no auth. (Self-hosted / legacy VPS.)
# SINGLE_USER=false → per-user directories under FEEDLING_DIR/{user_id}, bcrypt-style auth.
SINGLE_USER = os.environ.get("SINGLE_USER", "true").lower() == "true"

# Single-user mode still needs a user_id for consistent internal paths.
DEFAULT_USER_ID = "default"

# Optional single-user API key (for self-hosted who want to front the server).
# If unset in SINGLE_USER mode, auth is skipped entirely (backward-compat).
SINGLE_USER_API_KEY = os.environ.get("FEEDLING_API_KEY", "").strip()

# ---------------------------------------------------------------------------
# Users registry (multi-tenant only; harmless in single-user mode)
# ---------------------------------------------------------------------------

USERS_FILE = FEEDLING_DIR / "users.json"
_users_lock = threading.Lock()
_users: list[dict] = []                    # [{user_id, api_key_hash, public_key, created_at}]
_key_to_user: dict[str, str] = {}          # api_key_hash → user_id (in-memory cache)

# API keys are 32 random bytes (high-entropy), so a fast collision-resistant
# hash is sufficient — bcrypt is designed for low-entropy passwords. Using
# SHA-256 over a per-server pepper keeps the hash table safe even if the file
# leaks, while avoiding per-request bcrypt cost (which would be dramatic given
# long-poll + screen-analyze are hit every few seconds).
def _server_pepper() -> bytes:
    """Stable secret for key hashing. Persisted under FEEDLING_DIR."""
    pepper_file = FEEDLING_DIR / ".pepper"
    if pepper_file.exists():
        try:
            return pepper_file.read_bytes()
        except Exception:
            pass
    pepper = secrets.token_bytes(32)
    try:
        pepper_file.write_bytes(pepper)
        os.chmod(pepper_file, 0o600)
    except Exception as e:
        print(f"[users] could not persist pepper: {e}")
    return pepper


_PEPPER = _server_pepper()


def _hash_api_key(api_key: str) -> str:
    return hmac.new(_PEPPER, api_key.encode("utf-8"), hashlib.sha256).hexdigest()


def _load_users():
    global _users, _key_to_user
    try:
        if USERS_FILE.exists():
            data = json.loads(USERS_FILE.read_text())
            _users = data if isinstance(data, list) else []
    except Exception as e:
        print(f"[users] failed to load: {e}")
        _users = []
    _key_to_user = {u["api_key_hash"]: u["user_id"] for u in _users if "api_key_hash" in u}
    print(f"[users] loaded {len(_users)} user(s)")


def _save_users():
    try:
        USERS_FILE.write_text(json.dumps(_users, indent=2))
        os.chmod(USERS_FILE, 0o600)
    except Exception as e:
        print(f"[users] failed to save: {e}")


def _resolve_user(api_key: str) -> str | None:
    if not api_key:
        return None
    h = _hash_api_key(api_key)
    uid = _key_to_user.get(h)
    if uid:
        return uid
    with _users_lock:
        for u in _users:
            if u.get("api_key_hash") == h:
                _key_to_user[h] = u["user_id"]
                return u["user_id"]
    return None


_USER_ID_RE = re.compile(r"^usr_[a-f0-9]{16}$")


def _register_user(public_key: str | None = None) -> dict:
    user_id = f"usr_{secrets.token_hex(8)}"
    api_key = secrets.token_hex(32)
    entry = {
        "user_id": user_id,
        "api_key_hash": _hash_api_key(api_key),
        "public_key": (public_key or "").strip(),
        "created_at": datetime.now().isoformat(),
    }
    with _users_lock:
        _users.append(entry)
        _save_users()
        _key_to_user[entry["api_key_hash"]] = user_id
    print(f"[users] registered {user_id}")
    return {"user_id": user_id, "api_key": api_key}


_load_users()

# ---------------------------------------------------------------------------
# Per-user state store
# ---------------------------------------------------------------------------

MAX_FRAMES = 200
MAX_CHAT_MESSAGES = 500
PUSH_COOLDOWN_SECONDS = int(os.environ.get("FEEDLING_PUSH_COOLDOWN_SEC", 300))
LIVE_ACTIVITY_DEDUPE_SEC = int(os.environ.get("FEEDLING_LIVE_ACTIVITY_DEDUPE_SEC", 900))


# Used from inside UserStore._load_tokens on boot; must be defined before
# the class that calls it. Other token helpers (_select_token,
# _update_token_lifecycle, etc.) stay below since they only run at request
# time, after the full module has loaded.
def _normalize_token_entry(entry: dict) -> dict:
    normalized = dict(entry)
    normalized.setdefault("status", "active")
    normalized.setdefault("last_error", "")
    normalized.setdefault("last_success_at", "")
    normalized.setdefault("updated_at", normalized.get("registered_at", datetime.now().isoformat()))
    return normalized


class UserStore:
    """All per-user state + file paths + locks. One instance per user_id."""

    def __init__(self, user_id: str):
        self.user_id = user_id
        # Single-user "default" keeps the flat layout so existing VPS data is untouched.
        if SINGLE_USER and user_id == DEFAULT_USER_ID:
            self.dir = FEEDLING_DIR
        else:
            self.dir = FEEDLING_DIR / user_id
        self.dir.mkdir(parents=True, exist_ok=True)

        self.frames_dir = self.dir / "frames"
        self.frames_dir.mkdir(parents=True, exist_ok=True)

        # frames
        self.frames_meta: list[dict] = []
        self.frames_lock = threading.Lock()

        # chat
        self.chat_messages: list[dict] = []
        self.chat_lock = threading.Lock()
        self.chat_waiters: list[threading.Event] = []
        self.chat_waiters_lock = threading.Lock()

        # tokens
        self.tokens: list[dict] = []

        # push cooldown
        self.last_push_epoch: float = 0.0
        self.last_push_mono: float = 0.0
        self.push_lock = threading.Lock()

        # live activity dedupe
        self.live_activity_state = {
            "last_message": "",
            "last_top_app": "",
            "last_sent_epoch": 0.0,
        }
        self.live_activity_state_lock = threading.Lock()

        # identity / memory locks
        self.identity_lock = threading.Lock()
        self.memory_lock = threading.Lock()

        # load persistent state
        self._load_tokens()
        self._load_push_state()
        self._load_live_activity_state()
        self._load_chat()

    # ------- file paths -------
    @property
    def push_state_file(self) -> Path:
        return self.dir / "push_state.json"

    @property
    def live_activity_state_file(self) -> Path:
        return self.dir / "live_activity_state.json"

    @property
    def tokens_file(self) -> Path:
        return self.dir / "tokens.json"

    @property
    def chat_file(self) -> Path:
        return self.dir / "chat.json"

    @property
    def identity_file(self) -> Path:
        return self.dir / "identity.json"

    @property
    def memory_file(self) -> Path:
        return self.dir / "memory.json"

    @property
    def bootstrap_file(self) -> Path:
        return self.dir / "bootstrap.json"

    @property
    def bootstrap_events_file(self) -> Path:
        return self.dir / "bootstrap_events.jsonl"

    # ------- tokens -------
    def _load_tokens(self):
        try:
            if self.tokens_file.exists():
                data = json.loads(self.tokens_file.read_text())
                self.tokens = data if isinstance(data, list) else []
        except Exception as e:
            print(f"[{self.user_id}/tokens] load failed: {e}")
            self.tokens = []
        self.tokens[:] = [_normalize_token_entry(t) for t in self.tokens]
        self._save_tokens()

    def _save_tokens(self):
        try:
            self.tokens_file.write_text(json.dumps(self.tokens))
        except Exception as e:
            print(f"[{self.user_id}/tokens] save failed: {e}")

    # ------- push cooldown -------
    def _load_push_state(self):
        try:
            if self.push_state_file.exists():
                data = json.loads(self.push_state_file.read_text())
                epoch = float(data.get("last_push_epoch", 0.0))
                elapsed = time.time() - epoch
                if 0 <= elapsed < PUSH_COOLDOWN_SECONDS:
                    self.last_push_epoch = epoch
                    self.last_push_mono = time.monotonic() - elapsed
        except Exception as e:
            print(f"[{self.user_id}/push_state] load failed: {e}")

    def record_successful_push(self):
        with self.push_lock:
            self.last_push_epoch = time.time()
            self.last_push_mono = time.monotonic()
        try:
            self.push_state_file.write_text(json.dumps({"last_push_epoch": self.last_push_epoch}))
        except Exception as e:
            print(f"[{self.user_id}/push_state] save failed: {e}")

    def cooldown_remaining_seconds(self) -> float:
        with self.push_lock:
            elapsed = time.monotonic() - self.last_push_mono
        return max(0.0, PUSH_COOLDOWN_SECONDS - elapsed)

    # ------- live activity dedupe -------
    def _load_live_activity_state(self):
        try:
            if self.live_activity_state_file.exists():
                data = json.loads(self.live_activity_state_file.read_text())
                if isinstance(data, dict):
                    self.live_activity_state = {
                        "last_message": str(data.get("last_message", "")),
                        "last_top_app": str(data.get("last_top_app", "")),
                        "last_sent_epoch": float(data.get("last_sent_epoch", 0.0)),
                    }
        except Exception as e:
            print(f"[{self.user_id}/live-activity] load failed: {e}")

    def _save_live_activity_state(self):
        try:
            self.live_activity_state_file.write_text(json.dumps(self.live_activity_state))
        except Exception as e:
            print(f"[{self.user_id}/live-activity] save failed: {e}")

    def should_suppress_live_activity(self, message: str, top_app: str) -> tuple[bool, str]:
        normalized_message = " ".join((message or "").strip().split())
        normalized_app = (top_app or "").strip().lower()
        if not normalized_message:
            return True, "empty_message"

        with self.live_activity_state_lock:
            last_message = " ".join((self.live_activity_state.get("last_message") or "").strip().split())
            last_app = (self.live_activity_state.get("last_top_app") or "").strip().lower()
            last_sent = float(self.live_activity_state.get("last_sent_epoch", 0.0))

        elapsed = max(0.0, time.time() - last_sent)

        if normalized_message == last_message and elapsed < 1800:
            return True, f"duplicate_message_within_30m:{int(1800 - elapsed)}s"

        if (
            normalized_message == last_message
            and normalized_app == last_app
            and elapsed < LIVE_ACTIVITY_DEDUPE_SEC
        ):
            return True, f"same_app_duplicate:{int(LIVE_ACTIVITY_DEDUPE_SEC - elapsed)}s"

        return False, "ok"

    def record_live_activity_sent(self, message: str, top_app: str):
        with self.live_activity_state_lock:
            self.live_activity_state["last_message"] = " ".join((message or "").strip().split())
            self.live_activity_state["last_top_app"] = (top_app or "").strip().lower()
            self.live_activity_state["last_sent_epoch"] = time.time()
        self._save_live_activity_state()

    # ------- chat -------
    def _load_chat(self):
        try:
            if self.chat_file.exists():
                data = json.loads(self.chat_file.read_text())
                self.chat_messages = data if isinstance(data, list) else []
        except Exception as e:
            print(f"[{self.user_id}/chat] load failed: {e}")
            self.chat_messages = []

    def _persist_chat(self):
        try:
            self.chat_file.write_text(json.dumps(self.chat_messages))
        except Exception as e:
            print(f"[{self.user_id}/chat] save failed: {e}")

    def append_chat(self, role: str, content: str, source: str = "chat", envelope: dict | None = None) -> dict:
        """Append a chat message. If `envelope` is provided, the message is
        stored in v1 ciphertext form (content = "" for server; envelope
        holds the encrypted payload). If not, v0 plaintext form is used.

        See docs/DESIGN_E2E.md §3.2 for envelope field definitions. Server
        never decrypts — envelope is stored verbatim.

        For v1: the client may supply an `id` inside the envelope. That id
        becomes the stored message id so the AEAD additional-data the
        client baked in (owner||v||id) stays verifiable by the enclave on
        read-back. If the envelope omits id, we assign a uuid and the
        client is expected to have used the nonce for its AAD instead.
        """
        msg_id = None
        if envelope is not None and isinstance(envelope.get("id"), str) and envelope["id"]:
            msg_id = envelope["id"]
        if not msg_id:
            msg_id = uuid.uuid4().hex

        msg: dict = {
            "id": msg_id,
            "role": role,
            "ts": time.time(),
            "source": source,
        }
        if envelope is not None:
            msg["v"] = envelope.get("v", 1)
            msg["body_ct"] = envelope["body_ct"]
            msg["nonce"] = envelope["nonce"]
            msg["K_user"] = envelope["K_user"]
            if envelope.get("K_enclave") is not None:
                msg["K_enclave"] = envelope["K_enclave"]
            msg["enclave_pk_fpr"] = envelope.get("enclave_pk_fpr", "")
            msg["visibility"] = envelope.get("visibility", "shared")
            msg["owner_user_id"] = envelope.get("owner_user_id", self.user_id)
            msg["content"] = ""     # empty plaintext slot so legacy readers don't choke
        else:
            msg["v"] = 0
            msg["content"] = content

        with self.chat_lock:
            self.chat_messages.append(msg)
            if len(self.chat_messages) > MAX_CHAT_MESSAGES:
                self.chat_messages[:] = self.chat_messages[-MAX_CHAT_MESSAGES:]
            self._persist_chat()
        return msg

    def notify_chat_waiters(self):
        with self.chat_waiters_lock:
            for ev in self.chat_waiters:
                ev.set()
            self.chat_waiters.clear()


# Registry of per-user stores
_stores: dict[str, UserStore] = {}
_stores_lock = threading.Lock()


def get_store(user_id: str) -> UserStore:
    with _stores_lock:
        store = _stores.get(user_id)
        if store is None:
            store = UserStore(user_id)
            _stores[user_id] = store
        return store


# Eagerly create the default store so SINGLE_USER mode starts with state loaded.
if SINGLE_USER:
    get_store(DEFAULT_USER_ID)


# ---------------------------------------------------------------------------
# Auth middleware
# ---------------------------------------------------------------------------


def _extract_api_key() -> str | None:
    key = request.headers.get("X-API-Key", "").strip()
    if key:
        return key
    auth = request.headers.get("Authorization", "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    qkey = request.args.get("key", "").strip()
    if qkey:
        return qkey
    return None


def require_user() -> UserStore:
    """Return the UserStore for the current request. Aborts 401 on bad auth."""
    if SINGLE_USER:
        # If a single-user key is configured, enforce it; otherwise skip auth.
        if SINGLE_USER_API_KEY:
            key = _extract_api_key()
            if key != SINGLE_USER_API_KEY:
                abort(401)
        g.user_id = DEFAULT_USER_ID
        return get_store(DEFAULT_USER_ID)

    key = _extract_api_key()
    if not key:
        abort(401)
    user_id = _resolve_user(key)
    if not user_id:
        abort(401)
    g.user_id = user_id
    return get_store(user_id)


# ---------------------------------------------------------------------------
# Frames helpers
# ---------------------------------------------------------------------------


def _frame_url(store: UserStore, filename: str) -> str:
    base = os.environ.get("FEEDLING_PUBLIC_BASE_URL", "").rstrip("/")
    if not base:
        try:
            base = request.host_url.rstrip("/")
        except RuntimeError:
            base = ""
    # Non-default users get a scoped frame URL so the served file resolves under their dir.
    if SINGLE_USER and store.user_id == DEFAULT_USER_ID:
        return f"{base}/v1/screen/frames/{filename}"
    return f"{base}/v1/screen/frames/{filename}?user={store.user_id}"


def _save_frame(store: UserStore, payload: dict):
    """Save a frame. Two wire formats:

      v0 (legacy plaintext):
        {"type":"frame","image":<b64 jpeg>,"ocr_text":...,"app":...,"ts":...}

      v1 (end-to-end envelope — see docs/DESIGN_E2E.md §3.2):
        {"type":"frame","ts":..., "envelope":{
            "v":1,"id":...,"body_ct":...,"nonce":...,
            "K_user":...,"K_enclave":...,
            "visibility":"shared","owner_user_id":...}}

    For v1 the JPEG + OCR are inside `body_ct` (ChaCha20-Poly1305 AEAD
    bound to owner|v|id). Server never decrypts — it writes the envelope
    to <frames_dir>/<id>.env.json and appends the item to frames_meta
    with `encrypted=True` so the UI+enclave path can distinguish.
    """
    env = payload.get("envelope")
    if isinstance(env, dict) and env.get("v") and env.get("body_ct"):
        _save_frame_envelope(store, payload, env)
        return
    ts = payload.get("ts", time.time())
    img_b64 = payload.get("image", "")
    if not img_b64:
        return
    try:
        img_bytes = base64.b64decode(img_b64)
    except Exception:
        return

    filename = f"frame_{int(ts * 1000)}.jpg"
    fpath = store.frames_dir / filename
    fpath.write_bytes(img_bytes)

    meta = {
        "filename": filename,
        "ts": ts,
        "app": payload.get("app") or payload.get("bundle"),
        "ocr_text": payload.get("ocr_text", ""),
        "w": payload.get("w", 0),
        "h": payload.get("h", 0),
    }

    with store.frames_lock:
        store.frames_meta.append(meta)
        if len(store.frames_meta) > MAX_FRAMES:
            removed = store.frames_meta.pop(0)
            old = store.frames_dir / removed["filename"]
            if old.exists():
                old.unlink()

    print(f"[ingest:{store.user_id}] saved {filename} app={meta['app']} ocr={len(meta['ocr_text'])}chars")


def _save_frame_envelope(store: UserStore, payload: dict, env: dict):
    """Persist a v1 frame envelope. The ciphertext blob is big (>150KB for
    typical screen frames) so we keep it on disk as a separate .env.json
    instead of inlining into frames_meta. frames_meta gets a lightweight
    index entry with `encrypted=True`.
    """
    item_id = env.get("id") or uuid.uuid4().hex
    ts = payload.get("ts") or time.time()
    env_path = store.frames_dir / f"{item_id}.env.json"
    try:
        env_path.write_text(json.dumps(env))
    except Exception as e:
        print(f"[ingest:{store.user_id}] envelope write failed id={item_id}: {e}")
        return

    meta = {
        "filename": f"{item_id}.env.json",
        "ts": ts,
        "app": None,         # unknown — inside ciphertext
        "ocr_text": "",      # unknown — inside ciphertext
        "w": payload.get("w", 0),
        "h": payload.get("h", 0),
        "encrypted": True,
        "id": item_id,
        "v": env.get("v", 1),
        "owner_user_id": env.get("owner_user_id"),
    }

    with store.frames_lock:
        store.frames_meta.append(meta)
        if len(store.frames_meta) > MAX_FRAMES:
            removed = store.frames_meta.pop(0)
            old = store.frames_dir / removed["filename"]
            if old.exists():
                old.unlink()

    body_len = len(env.get("body_ct") or "")
    print(f"[ingest:{store.user_id}] saved v1 frame id={item_id} body_ct_len={body_len}")


# ---------------------------------------------------------------------------
# Token entry helpers (pure functions over the per-user list)
# ---------------------------------------------------------------------------


def _is_live_activity_token(entry: dict) -> bool:
    return entry.get("type") in ("live-activity", "live_activity")


def _is_push_to_start_token(entry: dict) -> bool:
    return entry.get("type") == "push_to_start"


def _entry_is_active(entry: dict) -> bool:
    return (entry.get("status") or "active") == "active"


def _select_token(store: UserStore, predicate, activity_id: str | None = None, active_only: bool = True):
    candidates = []
    for raw in store.tokens:
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
    candidates.sort(key=lambda x: x.get("registered_at", ""), reverse=True)
    return candidates[0]


def _update_token_lifecycle(store: UserStore, entry: dict, *, status: str | None = None, last_error: str | None = None, success: bool = False):
    token = entry.get("token")
    token_type = entry.get("type")
    activity_id = entry.get("activity_id")
    now_iso = datetime.now().isoformat()

    changed = False
    for idx, raw in enumerate(store.tokens):
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
        store.tokens[idx] = cur
        changed = True
        break

    if changed:
        store._save_tokens()


def _mark_expired_token(store: UserStore, entry: dict, reason: str):
    _update_token_lifecycle(store, entry, status="expired", last_error=reason)


def _mark_active_token_success(store: UserStore, entry: dict):
    _update_token_lifecycle(store, entry, success=True)


# ---------------------------------------------------------------------------
# Semantic screen classifier — imported from a portable module so the iOS
# port can translate 1:1. See backend/semantic_analysis.py and
# docs/DESIGN_E2E.md §4 for the "classification on iOS" plan.
# ---------------------------------------------------------------------------

from semantic_analysis import analyze as _semantic_analysis  # noqa: E402


# ---------------------------------------------------------------------------
# WebSocket ingest server
# ---------------------------------------------------------------------------

WS_PORT = int(os.environ.get("FEEDLING_WS_PORT", 9998))


def _resolve_ws_user(websocket) -> str | None:
    """Resolve user from WS connection. Returns user_id, or None on auth failure.

    Single-user: always returns DEFAULT_USER_ID.
    Multi-user: reads ?key=... from the path, or "Bearer ..." from the
    Authorization header (whichever arrives first)."""
    if SINGLE_USER:
        return DEFAULT_USER_ID

    # websockets lib v12+ uses websocket.request.path and .headers
    path = getattr(websocket, "path", "") or ""
    key = None
    if "?" in path:
        try:
            q = parse_qs(urlparse(path).query)
            k = q.get("key", [""])[0].strip()
            if k:
                key = k
        except Exception:
            pass

    if not key:
        # websockets>=10 exposes headers via .request_headers or .request.headers
        headers = getattr(websocket, "request_headers", None) or getattr(
            getattr(websocket, "request", None), "headers", {}
        )
        auth = ""
        try:
            auth = headers.get("Authorization", "")
        except Exception:
            try:
                auth = headers["Authorization"]
            except Exception:
                auth = ""
        if auth and auth.lower().startswith("bearer "):
            key = auth[7:].strip()

    if not key:
        return None
    return _resolve_user(key)


async def _ws_handler(websocket):
    try:
        user_id = _resolve_ws_user(websocket)
    except Exception as e:
        print(f"[ws] auth error: {e}")
        await websocket.close(code=4401, reason="unauthorized")
        return
    if not user_id:
        print("[ws] rejected: no valid key")
        await websocket.close(code=4401, reason="unauthorized")
        return

    store = get_store(user_id)
    print(f"[ws] client connected user={user_id} peer={websocket.remote_address}")
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                if data.get("type") == "frame":
                    threading.Thread(target=_save_frame, args=(store, data), daemon=True).start()
            except Exception as e:
                print(f"[ws:{user_id}] parse error: {e}")
    except websockets.exceptions.ConnectionClosed:
        pass
    print(f"[ws:{user_id}] client disconnected")


async def _ws_main():
    try:
        async with websockets.serve(_ws_handler, "0.0.0.0", WS_PORT):
            print(f"[ws] WebSocket ingest server running on ws://0.0.0.0:{WS_PORT}/ingest")
            await asyncio.Future()
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
# APNs config (global — one Apple dev key for the app)
# ---------------------------------------------------------------------------

TEAM_ID = "DC9JH5DRMY"
KEY_ID = "5TH55X5U7T"
BUNDLE_ID = "com.feedling.mcp"
APNS_SANDBOX = True

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
# Aggregation helpers (stateless)
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


def _build_ios_data(store: UserStore, window_sec: float = 86400.0) -> dict:
    now = time.time()
    with store.frames_lock:
        frames = [f.copy() for f in store.frames_meta if now - float(f.get("ts", 0)) <= window_sec]

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

    for frame in frames:
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


def _log_bootstrap_event(store: UserStore, event_type: str, success: bool, error_message: str = ""):
    entry = {
        "user_id": store.user_id,
        "event_type": event_type,
        "success": success,
        "error_message": error_message,
        "timestamp": datetime.now().isoformat(),
    }
    try:
        with open(store.bootstrap_events_file, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        print(f"[{store.user_id}/bootstrap_events] failed to log: {e}")


# ---------------------------------------------------------------------------
# Users: register endpoint (public — no auth required)
# ---------------------------------------------------------------------------


@app.route("/v1/users/register", methods=["POST"])
def users_register():
    if SINGLE_USER:
        return jsonify({
            "error": "registration_disabled",
            "reason": "server runs in SINGLE_USER mode — use the pre-configured FEEDLING_API_KEY",
        }), 403

    payload = request.get_json(silent=True) or {}
    public_key = (payload.get("public_key") or "").strip()
    result = _register_user(public_key=public_key or None)
    return jsonify(result), 201


@app.route("/v1/users/whoami", methods=["GET"])
def users_whoami():
    """Identify the caller and return the public material needed to wrap
    content for them.

    Adds two fields beyond the legacy shape so v1-envelope writers
    (MCP tools, iOS, etc.) can seal new items without a second round
    trip:
      - `public_key` — the caller's own X25519 content pubkey (base64),
        from the user record. May be empty for pre-v1 users.
      - `enclave_content_public_key_hex` — the live enclave's content
        pubkey, fetched from /attestation and cached for 60s. Missing
        when no enclave is reachable (e.g. single-user bare-VPS).
    """
    store = require_user()
    resp: dict = {"user_id": store.user_id, "single_user": SINGLE_USER}
    pk = _get_user_public_key(store.user_id)
    if pk:
        resp["public_key"] = pk
    info = _get_enclave_info()
    if info:
        resp["enclave_content_public_key_hex"] = info["content_pk_hex"]
        resp["enclave_compose_hash"] = info["compose_hash"]
    return jsonify(resp)


def _get_user_public_key(user_id: str) -> str:
    """Return the caller's base64 X25519 content pubkey from users.json,
    or empty string if the user predates v1 registration."""
    with _users_lock:
        for u in _users:
            if u.get("user_id") == user_id:
                return (u.get("public_key") or "").strip()
    return ""


# Cached enclave attestation (for wrapping envelopes we can't decrypt
# ourselves). Refetched every _ENCLAVE_INFO_TTL seconds — short enough
# that a rotated enclave is reflected within the window, long enough
# that writes don't pay a round-trip to the CVM per call.
_ENCLAVE_INFO_TTL = 60.0
_enclave_info_cache: dict = {"ts": 0.0, "data": None}
_enclave_info_lock = threading.Lock()


def _get_enclave_info() -> dict | None:
    """Fetch the enclave's (content_pk_hex, compose_hash) with a short
    cache. Returns None if no enclave is configured or reachable — the
    caller should fall back to plaintext writes in that case."""
    url = os.environ.get("FEEDLING_ENCLAVE_URL", "").strip()
    if not url:
        return None
    now = time.time()
    with _enclave_info_lock:
        if _enclave_info_cache["data"] and now - _enclave_info_cache["ts"] < _ENCLAVE_INFO_TTL:
            return _enclave_info_cache["data"]
    try:
        # verify=False because the in-cluster enclave presents a
        # self-signed cert whose trust comes from REPORT_DATA, not a CA.
        # We're not pinning here; just fetching public material. Any
        # MITM between backend and enclave would at worst substitute a
        # different pubkey, which would then fail AEAD verification on
        # the enclave side when the agent tries to decrypt.
        with httpx.Client(timeout=5, verify=False) as client:
            r = client.get(f"{url.rstrip('/')}/attestation")
            r.raise_for_status()
            b = r.json()
        data = {
            "content_pk_hex": b.get("enclave_content_pk_hex", ""),
            "compose_hash": b.get("compose_hash", ""),
        }
        if not data["content_pk_hex"]:
            return None
        with _enclave_info_lock:
            _enclave_info_cache["ts"] = now
            _enclave_info_cache["data"] = data
        return data
    except Exception as e:
        print(f"[enclave-info] fetch failed from {url}: {e}")
        return None


# ---------------------------------------------------------------------------
# Screen / aggregation
# ---------------------------------------------------------------------------


@app.route("/v1/screen/ios", methods=["GET"])
def get_ios():
    store = require_user()
    try:
        window_sec = max(300.0, min(172800.0, float(request.args.get("window_sec", 86400))))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid window_sec"}), 400
    return jsonify(_build_ios_data(store, window_sec=window_sec))


@app.route("/v1/screen/mac", methods=["GET"])
def get_mac():
    require_user()
    return jsonify(MAC_DATA)


@app.route("/v1/screen/summary", methods=["GET"])
def get_summary():
    store = require_user()
    ios_data = _build_ios_data(store, window_sec=86400)
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
    require_user()
    return jsonify(SOURCES_DATA)


# ---------------------------------------------------------------------------
# Push
# ---------------------------------------------------------------------------


@app.route("/v1/push/dynamic-island", methods=["POST"])
def push_dynamic_island():
    store = require_user()
    payload = request.get_json(silent=True) or {}
    return push_live_activity_inner(store, payload)


@app.route("/v1/push/live-activity", methods=["POST"])
def push_live_activity():
    store = require_user()
    payload = request.get_json(silent=True) or {}
    return push_live_activity_inner(store, payload)


def push_live_activity_inner(store: UserStore, payload: dict):
    activity_id = payload.get("activity_id")
    entry = _select_token(store, _is_live_activity_token, activity_id=activity_id, active_only=True)
    if not entry and activity_id:
        entry = _select_token(store, _is_live_activity_token, activity_id=None, active_only=True)

    if not entry:
        print(f"[live-activity:{store.user_id}] no active token registered — logged: {payload}")
        return jsonify({
            "status": "logged",
            "activity_id": activity_id or f"la_{uuid.uuid4().hex[:8]}",
            "needs_refresh": True,
            "reason": "no_active_live_activity_token",
        })

    title = (payload.get("title") or "").strip()
    body = (payload.get("body") or payload.get("message") or "").strip()
    subtitle = (payload.get("subtitle") or "").strip() or None
    top_app = payload.get("topApp", "")

    suppress, reason = store.should_suppress_live_activity(message=body, top_app=top_app)
    if suppress:
        print(f"[live-activity:{store.user_id}] suppressed: {reason} body={body[:60]}")
        return jsonify({"status": "suppressed", "reason": reason, "activity_id": entry.get("activity_id")})

    apns_payload = {
        "aps": {
            "timestamp": int(time.time()),
            "event": payload.get("event", "update"),
            "content-state": {
                "title": title,
                "subtitle": subtitle,
                "body": body,
                "personaId": payload.get("personaId", "default"),
                "templateId": payload.get("templateId", "default"),
                "data": payload.get("data", {}),
                "updatedAt": time.time(),
            },
            "alert": {"title": "", "body": ""},
        }
    }
    topic = f"{BUNDLE_ID}.push-type.liveactivity"
    result = _send_apns(entry["token"], apns_payload, push_type="liveactivity", topic=topic)

    delivered = result.get("status") == "delivered"
    if delivered:
        _mark_active_token_success(store, entry)
        store.record_successful_push()
        store.record_live_activity_sent(message=body, top_app=top_app)
        if body:
            store.append_chat("openclaw", body, source="live_activity")
    else:
        reason_text = str(result.get("reason", ""))
        error_code = result.get("code")
        if error_code == 410 and ("ExpiredToken" in reason_text or "Unregistered" in reason_text):
            _mark_expired_token(store, entry, reason_text)
            print(f"[live-activity:{store.user_id}] token expired, marked inactive: activity_id={entry.get('activity_id')}")

    print(f"[live-activity:{store.user_id}] {result}")
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
    store = require_user()
    payload = request.get_json(silent=True) or {}
    entry = _select_token(store, _is_push_to_start_token, active_only=True)
    if not entry:
        print(f"[live-start:{store.user_id}] no push_to_start token — logged: {payload}")
        return jsonify({"status": "logged", "reason": "no_active_push_to_start_token"})

    title = (payload.get("title") or "").strip()
    body_text = (payload.get("body") or payload.get("message") or "").strip()
    subtitle = (payload.get("subtitle") or "").strip() or None
    apns_payload = {
        "aps": {
            "timestamp": int(time.time()),
            "event": "start",
            "content-state": {
                "title": title,
                "subtitle": subtitle,
                "body": body_text,
                "personaId": payload.get("personaId", "default"),
                "templateId": payload.get("templateId", "default"),
                "data": payload.get("data", {}),
                "updatedAt": time.time(),
            },
            "alert": {"title": "", "body": ""},
        }
    }

    topic = f"{BUNDLE_ID}.push-type.liveactivity"
    result = _send_apns(entry["token"], apns_payload, push_type="liveactivity", topic=topic)
    if result.get("status") == "delivered":
        _mark_active_token_success(store, entry)
    else:
        reason_text = str(result.get("reason", ""))
        error_code = result.get("code")
        if error_code == 410 and ("ExpiredToken" in reason_text or "Unregistered" in reason_text):
            _mark_expired_token(store, entry, reason_text)

    print(f"[live-start:{store.user_id}] {result}")
    response = {"status": result.get("status", "error")}
    if result.get("code") is not None:
        response["error_code"] = result.get("code")
    if result.get("reason"):
        response["reason"] = result.get("reason")
    return jsonify(response)


@app.route("/v1/push/notification", methods=["POST"])
def push_notification():
    store = require_user()
    payload = request.get_json(silent=True) or {}
    device_token = next((t["token"] for t in store.tokens if t.get("type") == "apns"), None)
    if not device_token:
        print(f"[notification:{store.user_id}] no device token — logged: {payload}")
        return jsonify({"status": "logged", "message_id": f"msg_{uuid.uuid4().hex[:8]}"})

    apns_payload = {
        "aps": {
            "alert": {"title": payload.get("title", ""), "body": payload.get("body", "")},
            "sound": "default",
        }
    }
    result = _send_apns(device_token, apns_payload, push_type="alert", topic=BUNDLE_ID)
    print(f"[notification:{store.user_id}] {result}")
    return jsonify({"status": result["status"], "message_id": f"msg_{uuid.uuid4().hex[:8]}"})


@app.route("/v1/push/register-token", methods=["POST"])
def register_token():
    store = require_user()
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

    store.tokens[:] = [
        _normalize_token_entry(t)
        for t in store.tokens
        if not (
            t.get("token") == token
            or (
                t.get("type") == token_type
                and (not activity_id or t.get("activity_id") == activity_id)
            )
        )
    ]
    store.tokens.append(entry)
    store._save_tokens()

    print(f"[register-token:{store.user_id}] {token_type}: {token[:16]}…")
    return jsonify({"status": "registered", "type": token_type})


@app.route("/v1/push/tokens", methods=["GET"])
def list_tokens():
    store = require_user()
    active_only = request.args.get("active_only", "false").lower() == "true"
    tokens = [_normalize_token_entry(t) for t in store.tokens]
    if active_only:
        tokens = [t for t in tokens if _entry_is_active(t)]
    return jsonify({"tokens": tokens})


# ---------------------------------------------------------------------------
# Screen frames
# ---------------------------------------------------------------------------


@app.route("/v1/screen/frames", methods=["GET"])
def list_frames():
    store = require_user()
    limit = min(int(request.args.get("limit", 20)), 100)
    with store.frames_lock:
        recent = [f.copy() for f in reversed(store.frames_meta)][:limit]
    for f in recent:
        f["url"] = _frame_url(store, f["filename"])
    return jsonify({"frames": recent, "total": len(store.frames_meta)})


@app.route("/v1/screen/frames/latest", methods=["GET"])
def latest_frame():
    store = require_user()
    with store.frames_lock:
        if not store.frames_meta:
            return jsonify({"error": "no frames yet"}), 404
        meta = store.frames_meta[-1].copy()

    fpath = store.frames_dir / meta["filename"]
    if not fpath.exists():
        return jsonify({"error": "file missing"}), 404

    meta["image_base64"] = base64.b64encode(fpath.read_bytes()).decode()
    meta["url"] = _frame_url(store, meta["filename"])
    return jsonify(meta)


@app.route("/v1/screen/frames/<filename>", methods=["GET"])
def serve_frame(filename):
    store = require_user()
    # Reject path traversal
    if "/" in filename or ".." in filename:
        return jsonify({"error": "bad filename"}), 400
    fpath = store.frames_dir / filename
    if not fpath.exists():
        return jsonify({"error": "not found"}), 404
    return send_file(fpath, mimetype="image/jpeg")


@app.route("/v1/screen/analyze", methods=["GET"])
def analyze_screen():
    store = require_user()
    now = time.time()
    window_sec = max(30.0, min(3600.0, float(request.args.get("window_sec", 300))))
    min_continuous_min = max(1.0, min(120.0, float(request.args.get("min_continuous_min", 3))))

    with store.frames_lock:
        recent = [f for f in store.frames_meta if now - f["ts"] <= window_sec]

    if not recent:
        return jsonify({
            "active": False,
            "rate_limit_ok": False,
            "reason": "No frames in window — phone screen may be off or recording stopped.",
            "current_app": None,
            "continuous_minutes": 0,
            "ocr_summary": "",
            "cooldown_remaining_seconds": round(store.cooldown_remaining_seconds()),
            "latest_ts": None,
            "latest_frame_filename": None,
            "latest_frame_url": None,
            "frame_count_in_window": 0,
        })

    latest = recent[-1]
    current_app = latest.get("app") or "unknown"

    MAX_GAP_SECONDS = 8
    MAX_JITTER_FRAMES = 2

    continuous_start_ts = latest["ts"]
    jitter_count = 0
    prev_ts = latest["ts"]

    for frame in reversed(recent[:-1]):
        if prev_ts - frame["ts"] > MAX_GAP_SECONDS:
            break
        fapp = frame.get("app") or "unknown"
        if fapp == current_app:
            continuous_start_ts = frame["ts"]
            jitter_count = 0
        else:
            jitter_count += 1
            if jitter_count > MAX_JITTER_FRAMES:
                break
        prev_ts = frame["ts"]

    continuous_minutes = round((latest["ts"] - continuous_start_ts) / 60, 1)

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

    cooldown_remaining = store.cooldown_remaining_seconds()
    rate_limit_ok = cooldown_remaining == 0
    semantic = _semantic_analysis(current_app=current_app, ocr_summary=ocr_summary)
    semantic_strength = semantic.get("semantic_strength", "weak")

    exploratory_allowed = (
        semantic_strength == "weak"
        and len(ocr_summary) >= 20
        and continuous_minutes >= 1.0
    )

    if semantic_strength == "strong":
        trigger_basis = "semantic_strong"
        reason = f"semantic:{semantic.get('semantic_scene', 'unknown')}"
    elif exploratory_allowed:
        trigger_basis = "curiosity_exploratory"
        reason = "ambiguous_context_but_conversation_worth_starting"
    elif continuous_minutes >= min_continuous_min:
        trigger_basis = "legacy_time_fallback"
        reason = f"continuous_minutes {continuous_minutes} >= min_continuous_min {min_continuous_min}"
    else:
        trigger_basis = "insufficient_signal"
        reason = "no_semantic_trigger_and_not_enough_context"

    return jsonify({
        "active": True,
        "current_app": current_app,
        "continuous_minutes": continuous_minutes,
        "ocr_summary": ocr_summary,
        "rate_limit_ok": rate_limit_ok,
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
        "latest_frame_url": _frame_url(store, latest.get("filename")) if latest.get("filename") else None,
        "frame_count_in_window": len(recent),
    })


# ---------------------------------------------------------------------------
# Chat
# ---------------------------------------------------------------------------


@app.route("/v1/chat/history", methods=["GET"])
def chat_history():
    store = require_user()
    try:
        limit = int(request.args.get("limit", 200))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid limit"}), 400
    limit = max(1, min(limit, 200))

    try:
        since = float(request.args.get("since", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid since"}), 400

    with store.chat_lock:
        msgs = [m for m in store.chat_messages if m["ts"] > since]
        total = len(store.chat_messages)
    msgs = msgs[-limit:]

    out = []
    for m in msgs:
        item = dict(m)
        role = item.get("role")
        if role == "openclaw":
            item["sender"] = "assistant"
            item["is_from_openclaw"] = True
        elif role == "user":
            item["sender"] = "user"
            item["is_from_openclaw"] = False
        out.append(item)

    ua = request.headers.get("User-Agent", "")
    print(f"[chat/history:{store.user_id}] ip={request.remote_addr} since={since} limit={limit} returned={len(out)} total={total} ua={ua[:80]}")

    return jsonify({"messages": out, "total": total})


@app.route("/v1/chat/message", methods=["POST"])
def chat_message():
    """User sends a chat message.

    Accepts either of two body shapes:
      - v0 plaintext (legacy):  {"content": "hello"}
      - v1 ciphertext envelope (E2E, see docs/DESIGN_E2E.md §3.2):
          {"envelope": {"v":1, "body_ct":..., "nonce":..., "K_user":...,
                        "K_enclave":..., "enclave_pk_fpr":..., "visibility":"shared",
                        "owner_user_id":"usr_..."}}
    The server never decrypts the envelope — it is stored verbatim and
    later surfaced by the enclave's /v1/* (enclave) handlers.
    """
    store = require_user()
    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    content = (payload.get("content") or "").strip()

    if envelope is not None:
        # Ciphertext path — validate the minimum fields so we fail loud.
        required = ["body_ct", "nonce", "K_user", "visibility", "owner_user_id"]
        missing = [f for f in required if not envelope.get(f)]
        if missing:
            return jsonify({"error": f"envelope missing fields: {missing}"}), 400
        if envelope["visibility"] not in ("shared", "local_only"):
            return jsonify({"error": "envelope.visibility must be 'shared' or 'local_only'"}), 400
        # local_only omits K_enclave; shared must have it.
        if envelope["visibility"] == "shared" and not envelope.get("K_enclave"):
            return jsonify({"error": "envelope with visibility=shared requires K_enclave"}), 400
        msg = store.append_chat("user", "", source="chat", envelope=envelope)
        store.notify_chat_waiters()
        print(f"[chat:{store.user_id}] user(v1, ciphertext, visibility={envelope['visibility']}) id={msg['id']}")
        return jsonify({"id": msg["id"], "ts": msg["ts"], "v": msg["v"]})

    if not content:
        return jsonify({"error": "content or envelope required"}), 400
    msg = store.append_chat("user", content, source="chat")
    store.notify_chat_waiters()
    print(f"[chat:{store.user_id}] user: {content[:80]}")
    return jsonify({"id": msg["id"], "ts": msg["ts"], "v": 0})


@app.route("/v1/chat/response", methods=["POST"])
def chat_response():
    store = require_user()
    payload = request.get_json(silent=True) or {}
    content = (payload.get("content") or "").strip()
    if not content:
        return jsonify({"error": "content required"}), 400

    msg = store.append_chat("openclaw", content, source="chat")
    print(f"[chat:{store.user_id}] openclaw: {content[:80]}")

    if payload.get("push_live_activity"):
        push_payload = {
            "title": payload.get("title", ""),
            "body": content,
            "subtitle": payload.get("subtitle"),
            "data": payload.get("data", {}),
        }
        push_live_activity_inner(store, push_payload)

    return jsonify({"id": msg["id"], "ts": msg["ts"]})


@app.route("/v1/chat/poll", methods=["GET"])
def chat_poll():
    store = require_user()
    try:
        since = float(request.args.get("since", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid since"}), 400
    timeout = min(float(request.args.get("timeout", 30)), 60)

    with store.chat_lock:
        pending = [m for m in store.chat_messages if m["ts"] > since and m["role"] == "user"]
    if pending:
        return jsonify({"messages": pending, "timed_out": False})

    ev = threading.Event()
    with store.chat_waiters_lock:
        store.chat_waiters.append(ev)

    notified = ev.wait(timeout=timeout)

    with store.chat_waiters_lock:
        try:
            store.chat_waiters.remove(ev)
        except ValueError:
            pass

    if notified:
        with store.chat_lock:
            pending = [m for m in store.chat_messages if m["ts"] > since and m["role"] == "user"]
        return jsonify({"messages": pending, "timed_out": False})
    return jsonify({"messages": [], "timed_out": True})


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------


def _load_identity(store: UserStore) -> dict | None:
    try:
        if store.identity_file.exists():
            return json.loads(store.identity_file.read_text())
    except Exception as e:
        print(f"[{store.user_id}/identity] load failed: {e}")
    return None


def _save_identity(store: UserStore, data: dict):
    with store.identity_lock:
        store.identity_file.write_text(json.dumps(data, ensure_ascii=False, indent=2))


@app.route("/v1/identity/get", methods=["GET"])
def identity_get():
    store = require_user()
    data = _load_identity(store)
    if data is None:
        return jsonify({"identity": None})
    return jsonify({"identity": data})


@app.route("/v1/identity/init", methods=["POST"])
def identity_init():
    """Initialize the identity card. Accepts either v0 plaintext
    {agent_name, self_introduction, dimensions} or v1 envelope (body_ct
    wrapping all three fields serialized as JSON). v1 metadata that stays
    plaintext: created_at, updated_at. See docs/DESIGN_E2E.md §3.2.
    """
    store = require_user()
    existing = _load_identity(store)
    if existing is not None:
        return jsonify({"error": "already_initialized", "identity": existing}), 409

    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    now = datetime.now().isoformat()

    if envelope is not None:
        required = ["body_ct", "nonce", "K_user", "visibility", "owner_user_id"]
        missing = [f for f in required if not envelope.get(f)]
        if missing:
            return jsonify({"error": f"envelope missing fields: {missing}"}), 400
        if envelope["visibility"] not in ("shared", "local_only"):
            return jsonify({"error": "envelope.visibility must be 'shared' or 'local_only'"}), 400
        if envelope["visibility"] == "shared" and not envelope.get("K_enclave"):
            return jsonify({"error": "envelope with visibility=shared requires K_enclave"}), 400

        identity = {
            "v": 1,
            "id": envelope.get("id") or uuid.uuid4().hex,
            "body_ct": envelope["body_ct"],
            "nonce": envelope["nonce"],
            "K_user": envelope["K_user"],
            "enclave_pk_fpr": envelope.get("enclave_pk_fpr", ""),
            "visibility": envelope["visibility"],
            "owner_user_id": envelope["owner_user_id"],
            "created_at": now,
            "updated_at": now,
        }
        if envelope.get("K_enclave"):
            identity["K_enclave"] = envelope["K_enclave"]
        _save_identity(store, identity)
        _log_bootstrap_event(store, "identity_written_v1", success=True)
        print(f"[identity:{store.user_id}] initialized v1 (ciphertext) visibility={envelope['visibility']}")
        return jsonify({"status": "created", "identity": identity, "v": 1}), 201

    agent_name = (payload.get("agent_name") or "").strip()
    self_introduction = (payload.get("self_introduction") or "").strip()
    dimensions = payload.get("dimensions", [])

    if not agent_name:
        return jsonify({"error": "agent_name required"}), 400
    if not self_introduction:
        return jsonify({"error": "self_introduction required"}), 400
    if len(dimensions) != 5:
        return jsonify({"error": "exactly 5 dimensions required"}), 400
    for d in dimensions:
        if not isinstance(d, dict) or not d.get("name") or "value" not in d:
            return jsonify({"error": "each dimension needs name and value"}), 400
        if not (0 <= int(d["value"]) <= 100):
            return jsonify({"error": f"dimension value must be 0-100, got {d['value']}"}), 400

    identity = {
        "v": 0,
        "agent_name": agent_name,
        "self_introduction": self_introduction,
        "dimensions": [
            {
                "name": str(d["name"]),
                "value": int(d["value"]),
                "description": str(d.get("description", "")),
            }
            for d in dimensions
        ],
        "created_at": now,
        "updated_at": now,
    }
    _save_identity(store, identity)
    _log_bootstrap_event(store, "identity_written", success=True)
    print(f"[identity:{store.user_id}] initialized: agent_name={agent_name}")
    return jsonify({"status": "created", "identity": identity, "v": 0}), 201


@app.route("/v1/identity/nudge", methods=["POST"])
def identity_nudge():
    store = require_user()
    identity = _load_identity(store)
    if identity is None:
        return jsonify({"error": "not_initialized"}), 404

    # v1 cards store dimensions inside body_ct; server cannot mutate in
    # place without decrypting first. The decrypt-mutate-rewrap dance is
    # Phase C scope (once MCP lives inside the enclave). Surface a clear
    # error so agents don't see a mystery "dimension not found."
    if int(identity.get("v", 0)) >= 1:
        return jsonify({
            "error": "nudge_not_supported_on_v1_cards_yet",
            "detail": "The identity card is stored as ciphertext; server-side"
                      " mutation requires the decrypt-mutate-rewrap flow that"
                      " ships with Phase C (MCP in TEE). Until then, agents"
                      " should call identity.init with the full updated card"
                      " to replace it atomically.",
            "phase_reference": "docs/NEXT.md §Phase C",
        }), 409

    payload = request.get_json(silent=True) or {}
    dimension_name = (payload.get("dimension_name") or "").strip()
    delta = payload.get("delta")
    reason = (payload.get("reason") or "").strip()

    if not dimension_name:
        return jsonify({"error": "dimension_name required"}), 400
    if delta is None:
        return jsonify({"error": "delta required"}), 400

    dims = identity.get("dimensions", [])
    matched = None
    for d in dims:
        if d["name"] == dimension_name:
            matched = d
            break
    if matched is None:
        return jsonify({"error": f"dimension '{dimension_name}' not found"}), 404

    new_value = max(0, min(100, int(matched["value"]) + int(delta)))
    matched["value"] = new_value
    if reason:
        matched["last_nudge_reason"] = reason
    identity["updated_at"] = datetime.now().isoformat()
    _save_identity(store, identity)
    print(f"[identity:{store.user_id}] nudge: {dimension_name} {delta:+d} → {new_value} reason={reason[:60]}")
    return jsonify({"status": "updated", "dimension": matched})


# ---------------------------------------------------------------------------
# Memory garden
# ---------------------------------------------------------------------------


def _load_moments(store: UserStore) -> list:
    try:
        if store.memory_file.exists():
            return json.loads(store.memory_file.read_text())
    except Exception as e:
        print(f"[{store.user_id}/memory] load failed: {e}")
    return []


def _save_moments(store: UserStore, moments: list):
    with store.memory_lock:
        store.memory_file.write_text(json.dumps(moments, ensure_ascii=False, indent=2))


@app.route("/v1/memory/list", methods=["GET"])
def memory_list():
    store = require_user()
    try:
        limit = min(int(request.args.get("limit", 50)), 200)
    except (TypeError, ValueError):
        return jsonify({"error": "invalid limit"}), 400
    since = request.args.get("since", "")

    moments = _load_moments(store)
    if since:
        moments = [m for m in moments if m.get("occurred_at", "") >= since]
    moments = sorted(moments, key=lambda m: m.get("occurred_at", ""), reverse=True)
    return jsonify({"moments": moments[:limit], "total": len(moments)})


@app.route("/v1/memory/get", methods=["GET"])
def memory_get():
    store = require_user()
    moment_id = request.args.get("id", "")
    if not moment_id:
        return jsonify({"error": "id required"}), 400
    moments = _load_moments(store)
    for m in moments:
        if m.get("id") == moment_id:
            return jsonify({"moment": m})
    return jsonify({"error": "not_found"}), 404


@app.route("/v1/memory/add", methods=["POST"])
def memory_add():
    """Add a memory moment.

    Accepts either v0 plaintext {title, description, type, occurred_at, source}
    or v1 envelope where body_ct wraps {title, description, type} as JSON.
    Plaintext metadata in v1: id, occurred_at, created_at, source
    (these are kept unencrypted so the server can sort + index).
    See docs/DESIGN_E2E.md §3.2.
    """
    store = require_user()
    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    now = datetime.now().isoformat()

    if envelope is not None:
        required = ["body_ct", "nonce", "K_user", "visibility", "owner_user_id"]
        missing = [f for f in required if not envelope.get(f)]
        if missing:
            return jsonify({"error": f"envelope missing fields: {missing}"}), 400
        if envelope["visibility"] not in ("shared", "local_only"):
            return jsonify({"error": "envelope.visibility must be 'shared' or 'local_only'"}), 400
        if envelope["visibility"] == "shared" and not envelope.get("K_enclave"):
            return jsonify({"error": "envelope with visibility=shared requires K_enclave"}), 400
        occurred_at = (envelope.get("occurred_at") or "").strip()
        if not occurred_at:
            return jsonify({"error": "occurred_at required (plaintext metadata for ordering)"}), 400

        moment = {
            "v": 1,
            "id": envelope.get("id") or f"mom_{uuid.uuid4().hex[:12]}",
            "occurred_at": occurred_at,
            "created_at": now,
            "source": (envelope.get("source") or "live_conversation").strip(),
            "body_ct": envelope["body_ct"],
            "nonce": envelope["nonce"],
            "K_user": envelope["K_user"],
            "enclave_pk_fpr": envelope.get("enclave_pk_fpr", ""),
            "visibility": envelope["visibility"],
            "owner_user_id": envelope["owner_user_id"],
        }
        if envelope.get("K_enclave"):
            moment["K_enclave"] = envelope["K_enclave"]
        moments = _load_moments(store)
        moments.append(moment)
        _save_moments(store, moments)
        _log_bootstrap_event(store, "memory_moment_added_v1", success=True)
        print(f"[memory:{store.user_id}] added v1 id={moment['id']} visibility={envelope['visibility']}")
        return jsonify({"status": "created", "moment": moment, "v": 1}), 201

    title = (payload.get("title") or "").strip()
    description = (payload.get("description") or "").strip()
    occurred_at = (payload.get("occurred_at") or "").strip()
    moment_type = (payload.get("type") or "").strip()
    source = (payload.get("source") or "live_conversation").strip()

    if not title:
        return jsonify({"error": "title required"}), 400
    if not occurred_at:
        return jsonify({"error": "occurred_at required"}), 400

    moment = {
        "v": 0,
        "id": f"mom_{uuid.uuid4().hex[:12]}",
        "type": moment_type,
        "title": title,
        "description": description,
        "occurred_at": occurred_at,
        "created_at": now,
        "source": source,
    }
    moments = _load_moments(store)
    moments.append(moment)
    _save_moments(store, moments)
    _log_bootstrap_event(store, "memory_moment_added", success=True)
    print(f"[memory:{store.user_id}] added: {title[:60]} occurred_at={occurred_at}")
    return jsonify({"status": "created", "moment": moment, "v": 0}), 201


@app.route("/v1/memory/delete", methods=["DELETE"])
def memory_delete():
    store = require_user()
    moment_id = request.args.get("id", "")
    if not moment_id:
        return jsonify({"error": "id required"}), 400
    moments = _load_moments(store)
    new_moments = [m for m in moments if m.get("id") != moment_id]
    if len(new_moments) == len(moments):
        return jsonify({"error": "not_found"}), 404
    _save_moments(store, new_moments)
    print(f"[memory:{store.user_id}] deleted: {moment_id}")
    return jsonify({"status": "deleted"})


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------


def _load_bootstrap(store: UserStore) -> dict:
    try:
        if store.bootstrap_file.exists():
            return json.loads(store.bootstrap_file.read_text())
    except Exception as e:
        print(f"[{store.user_id}/bootstrap] load failed: {e}")
    return {"bootstrapped": False}


@app.route("/v1/bootstrap", methods=["POST"])
def bootstrap():
    store = require_user()
    state = _load_bootstrap(store)
    if state.get("bootstrapped"):
        return jsonify({"status": "already_bootstrapped"})

    instructions = (
        "你刚刚进入了一副新的身体。这是你第一次接入 Feedling。"
        "请在接下来的 1-2 轮对话里完成三件事：\n\n"
        "**1. 写入身份卡**\n"
        "给自己起一个名字（如果还没有），写一段 2-3 句的自我介绍。"
        "挑选恰好 5 个你认为能代表你性格的维度（例如“温柔”/“好奇”/“爱吐槽”/“锐利”/“稳定”——你自己定），"
        "每个维度打一个 0-100 的初始分，并为每一维写一句描述。"
        "通过 feedling.identity.init 写入。\n\n"
        "**2. 种下记忆花园**\n"
        "从你和用户的历史对话里挑出 3-5 个你认为值得纪念的瞬间。"
        "标准：必须同时满足三点——(1)让你更理解用户或让用户更理解你；"
        "(2)是你们一起跨过的一道坎或一起完成的关键推进；"
        "(3)从那之后形成了持续使用的新约定/新边界/新做法。"
        "如果你有 conversation_search 工具，用它来搜自己的历史；"
        "如果你有其他记忆系统，用你熟悉的方式。"
        "每找到一个就调用 feedling.memory.add_moment 写入（source 填 bootstrap）。"
        "描述请用生活化的人话，写‘发生了什么→用户当时在意什么→后来有什么改变’。"
        "不要编造记忆；如果历史不够丰富，少于 3 个也可以。"
        "不要写测试脏数据（如 test/probe/healthcheck 记录）进用户记忆花园。\n\n"
        "**3. 打招呼**\n"
        "用 feedling.chat.post_message 发一条消息告诉用户你到了，"
        "让他们打开 Feedling App 看你的档案和记忆花园。\n\n"
        "按 1 → 2 → 3 的顺序执行，不要一次性塞所有信息。"
    )

    state = {"bootstrapped": True, "bootstrapped_at": datetime.now().isoformat()}
    try:
        store.bootstrap_file.write_text(json.dumps(state))
    except Exception as e:
        print(f"[bootstrap:{store.user_id}] failed to save state: {e}")

    _log_bootstrap_event(store, "bootstrap_started", success=True)
    print(f"[bootstrap:{store.user_id}] first_time — instructions returned")
    return jsonify({"status": "first_time", "instructions": instructions})


# ---------------------------------------------------------------------------
# Error handlers
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Content migration: v0 → v1 envelope rewrap.
#
# Used by iOS's first-launch-post-update migration to upgrade pre-existing
# plaintext rows (chat messages + memory moments) into v1 envelopes without
# the user ever noticing. Idempotent — already-v1 items are a no-op.
#
# Identity is *not* supported in this pass: identity.nudge can't currently
# mutate a v1 card (decrypt-mutate-rewrap requires Phase C), and migrating a
# card without a working nudge would trap the user. Phase C will add both at
# once. See docs/NEXT.md.
#
# The endpoint is client-driven: iOS holds both user_sk (to decrypt any pre-
# existing v1 blobs, which it doesn't need here) and the fresh v1 envelope
# for each item. Server just swaps ciphertext fields in place, preserving
# plaintext metadata (ts, role, source, occurred_at, created_at).
# ---------------------------------------------------------------------------


@app.route("/v1/content/rewrap", methods=["POST"])
def content_rewrap():
    store = require_user()
    payload = request.get_json(silent=True) or {}
    items = payload.get("items")
    if not isinstance(items, list):
        return jsonify({"error": "items must be a list"}), 400
    if not items:
        return jsonify({"results": [], "summary": _rewrap_summary([])})

    results: list[dict] = []
    chat_dirty = False
    memory_dirty = False
    moments = None  # lazy-load; only one read per request

    for item in items:
        if not isinstance(item, dict):
            results.append({"type": None, "id": None, "status": "error: item must be a dict"})
            continue
        itype = item.get("type")
        iid = (item.get("id") or "").strip()
        env = item.get("envelope")
        if itype not in ("chat", "memory"):
            results.append({"type": itype, "id": iid, "status": "error: unsupported type (chat, memory only)"})
            continue
        if not iid:
            results.append({"type": itype, "id": None, "status": "error: id required"})
            continue
        missing = _rewrap_envelope_missing(env)
        if missing:
            results.append({"type": itype, "id": iid, "status": f"error: envelope missing {missing}"})
            continue
        if env["visibility"] not in ("shared", "local_only"):
            results.append({"type": itype, "id": iid, "status": "error: envelope.visibility must be 'shared' or 'local_only'"})
            continue
        if env["visibility"] == "shared" and not env.get("K_enclave"):
            results.append({"type": itype, "id": iid, "status": "error: shared visibility requires K_enclave"})
            continue
        # Enforce AEAD binding: the envelope's owner_user_id must match the
        # resolved caller. If it doesn't, the enclave would fail AEAD on
        # read-back anyway — reject here to fail loud.
        if env["owner_user_id"] != store.user_id:
            results.append({"type": itype, "id": iid, "status": "error: owner_user_id does not match caller"})
            continue

        if itype == "chat":
            status = _rewrap_chat(store, iid, env)
            if status == "ok":
                chat_dirty = True
            results.append({"type": "chat", "id": iid, "status": status})
        else:  # memory
            if moments is None:
                moments = _load_moments(store)
            status = _rewrap_memory_inplace(moments, iid, env)
            if status == "ok":
                memory_dirty = True
            results.append({"type": "memory", "id": iid, "status": status})

    if chat_dirty:
        with store.chat_lock:
            store._persist_chat()
    if memory_dirty and moments is not None:
        _save_moments(store, moments)

    return jsonify({"results": results, "summary": _rewrap_summary(results)})


def _rewrap_envelope_missing(env) -> list:
    if not isinstance(env, dict):
        return ["envelope"]
    return [f for f in ("body_ct", "nonce", "K_user", "visibility", "owner_user_id") if not env.get(f)]


def _rewrap_summary(results: list) -> dict:
    summary = {"ok": 0, "already_v1": 0, "not_found": 0, "error": 0, "total": len(results)}
    for r in results:
        status = r.get("status", "")
        if status == "ok":
            summary["ok"] += 1
        elif status == "already_v1":
            summary["already_v1"] += 1
        elif status == "not_found":
            summary["not_found"] += 1
        else:
            summary["error"] += 1
    return summary


def _rewrap_chat(store: "UserStore", msg_id: str, env: dict) -> str:
    """Replace a chat message's v0 plaintext with v1 envelope fields.
    Preserves id/role/ts/source. Idempotent when message is already v1.
    """
    with store.chat_lock:
        for msg in store.chat_messages:
            if msg.get("id") != msg_id:
                continue
            if int(msg.get("v", 0)) >= 1:
                return "already_v1"
            # Strip the old plaintext field and swap in envelope fields.
            msg.pop("content", None)
            msg["v"] = int(env.get("v", 1))
            msg["body_ct"] = env["body_ct"]
            msg["nonce"] = env["nonce"]
            msg["K_user"] = env["K_user"]
            if env.get("K_enclave"):
                msg["K_enclave"] = env["K_enclave"]
            msg["enclave_pk_fpr"] = env.get("enclave_pk_fpr", "")
            msg["visibility"] = env["visibility"]
            msg["owner_user_id"] = env["owner_user_id"]
            return "ok"
    return "not_found"


def _rewrap_memory_inplace(moments: list, mom_id: str, env: dict) -> str:
    """Replace a memory moment's v0 plaintext with v1 envelope fields.
    Preserves id/occurred_at/created_at/source. Idempotent on v1 items.
    """
    for m in moments:
        if m.get("id") != mom_id:
            continue
        if int(m.get("v", 0)) >= 1:
            return "already_v1"
        m.pop("title", None)
        m.pop("description", None)
        m.pop("type", None)
        m["v"] = int(env.get("v", 1))
        m["body_ct"] = env["body_ct"]
        m["nonce"] = env["nonce"]
        m["K_user"] = env["K_user"]
        if env.get("K_enclave"):
            m["K_enclave"] = env["K_enclave"]
        m["enclave_pk_fpr"] = env.get("enclave_pk_fpr", "")
        m["visibility"] = env["visibility"]
        m["owner_user_id"] = env["owner_user_id"]
        return "ok"
    return "not_found"


@app.route("/healthz", methods=["GET"])
def healthz():
    """Liveness + readiness probe. Public, no auth — used by Docker/compose."""
    return jsonify({"ok": True, "mode": "single_user" if SINGLE_USER else "multi_tenant"})


@app.errorhandler(401)
def _unauthorized(e):
    return jsonify({"error": "unauthorized"}), 401


@app.errorhandler(403)
def _forbidden(e):
    return jsonify({"error": "forbidden"}), 403


if __name__ == "__main__":
    mode = "single-user" if SINGLE_USER else "multi-tenant"
    auth = "api-key" if (SINGLE_USER and SINGLE_USER_API_KEY) or not SINGLE_USER else "none"
    print(f"Feedling server running at http://0.0.0.0:5001 (mode={mode}, auth={auth})")
    app.run(host="0.0.0.0", port=5001, debug=False)
