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
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import httpx
import jwt
import websockets
from flask import Flask, abort, g, jsonify, request, Response, send_file
from flask_compress import Compress

# ---------------------------------------------------------------------------
# Root directory + deployment mode
# ---------------------------------------------------------------------------

FEEDLING_DIR = Path(os.environ.get("FEEDLING_DATA_DIR", str(Path.home() / "feedling-data"))).expanduser()
FEEDLING_DIR.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Users registry (multi-tenant). Every request is auth'd by api_key.
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
# Chat history ring buffer per user. Bumped from 500 → 5000 on 2026-05-11
# to give users meaningful scroll-back across months of normal use without
# silently losing their oldest conversations. At ~800 bytes per text-only
# envelope this caps chat.json around 4 MB; image-heavy users will see it
# grow into the tens of MB because envelopes carry the encrypted JPEG
# inline. Each chat append rewrites the whole file (see _persist_chat),
# so the bigger the file, the slower the write — at 5000 the per-message
# write cost is roughly 100-500 ms depending on image density. If that
# starts mattering, the next step is switching chat persistence to an
# append-only JSONL log so writes become O(1) regardless of history depth.
MAX_CHAT_MESSAGES = 5000
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
        self._load_frames_meta()

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

    @property
    def frames_meta_file(self) -> Path:
        return self.dir / "frames_meta.json"

    # ------- frames index -------
    def _load_frames_meta(self):
        # Fast path: index file already persisted.
        if self.frames_meta_file.exists():
            try:
                data = json.loads(self.frames_meta_file.read_text())
                if isinstance(data, list):
                    self.frames_meta = data
                    print(f"[{self.user_id}/frames] loaded index n={len(self.frames_meta)}")
                    return
            except Exception as e:
                print(f"[{self.user_id}/frames] index load failed: {e} — rebuilding from disk")

        # Rebuild path: no index yet (first boot with this fix, or pre-fix restart
        # left orphan env.json files). Scan frames_dir and reconstruct meta from
        # envelope bodies + file mtime. ts fallback loses sub-second precision but
        # is good enough to un-orphan pre-fix frames.
        recovered: list[dict] = []
        try:
            for p in sorted(self.frames_dir.glob("*.env.json")):
                try:
                    env = json.loads(p.read_text())
                    if not isinstance(env, dict) or not env.get("body_ct"):
                        continue
                    recovered.append({
                        "filename": p.name,
                        "ts": p.stat().st_mtime,
                        "app": None,
                        "ocr_text": "",
                        "w": 0,
                        "h": 0,
                        "encrypted": True,
                        "id": env.get("id") or p.stem.split(".")[0],
                        "v": env.get("v", 1),
                        "owner_user_id": env.get("owner_user_id"),
                    })
                except Exception as e:
                    print(f"[{self.user_id}/frames] skip {p.name}: {e}")
            recovered.sort(key=lambda m: m["ts"])
            if len(recovered) > MAX_FRAMES:
                # Keep the newest MAX_FRAMES; prune orphan files for the rest.
                drop = recovered[:-MAX_FRAMES]
                recovered = recovered[-MAX_FRAMES:]
                for m in drop:
                    try:
                        (self.frames_dir / m["filename"]).unlink(missing_ok=True)
                    except Exception:
                        pass
            self.frames_meta = recovered
            self._persist_frames_meta()
            print(f"[{self.user_id}/frames] rebuilt index from disk n={len(recovered)}")
        except Exception as e:
            print(f"[{self.user_id}/frames] rebuild failed: {e}")
            self.frames_meta = []

    def _persist_frames_meta(self):
        try:
            tmp = self.frames_meta_file.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(self.frames_meta))
            tmp.replace(self.frames_meta_file)
        except Exception as e:
            print(f"[{self.user_id}/frames] index save failed: {e}")

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

    def append_chat(
        self,
        role: str,
        source: str,
        envelope: dict,
        content_type: str = "text",
    ) -> dict:
        """Append a v1 ciphertext chat message. `envelope` holds the AEAD
        payload. See docs/DESIGN_E2E.md §3.2 for field definitions. Server
        never decrypts — the envelope is stored verbatim.

        The client supplies the envelope's `id`, which becomes the stored
        message id so the AEAD additional-data the client baked in
        (owner||v||id) stays verifiable by the enclave on read-back.

        `content_type` is plaintext metadata: "text" (default) or "image".
        Used by clients/enclave to render the decrypted bytes correctly —
        the envelope itself only carries opaque bytes; the type tag tells
        the renderer to show a string vs decode JPEG.
        """
        msg_id = envelope.get("id") if isinstance(envelope.get("id"), str) and envelope["id"] else uuid.uuid4().hex
        ct = content_type if content_type in ("text", "image") else "text"

        msg: dict = {
            "id": msg_id,
            "role": role,
            "ts": time.time(),
            "source": source,
            "v": envelope.get("v", 1),
            "body_ct": envelope["body_ct"],
            "nonce": envelope["nonce"],
            "K_user": envelope["K_user"],
            "enclave_pk_fpr": envelope.get("enclave_pk_fpr", ""),
            "visibility": envelope.get("visibility", "shared"),
            "owner_user_id": envelope.get("owner_user_id", self.user_id),
            "content_type": ct,
        }
        if envelope.get("K_enclave") is not None:
            msg["K_enclave"] = envelope["K_enclave"]

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
    return f"{base}/v1/screen/frames/{filename}?user={store.user_id}"


def _save_frame(store: UserStore, payload: dict):
    """Save a v1 frame envelope. See docs/DESIGN_E2E.md §3.2.

    Wire format:
      {"type":"frame","ts":..., "envelope":{
          "v":1,"id":...,"body_ct":...,"nonce":...,
          "K_user":...,"K_enclave":...,
          "visibility":"shared","owner_user_id":...}}

    The JPEG + OCR are inside `body_ct` (ChaCha20-Poly1305 AEAD bound to
    owner|v|id). Server never decrypts — it writes the envelope to
    <frames_dir>/<id>.env.json and appends the item to frames_meta with
    `encrypted=True` so the UI + enclave path can find it.
    """
    env = payload.get("envelope")
    if not (isinstance(env, dict) and env.get("v") and env.get("body_ct")):
        print(f"[ingest:{store.user_id}] rejecting frame without v1 envelope")
        return
    _save_frame_envelope(store, payload, env)


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
        store._persist_frames_meta()

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

    Reads ?key=... from the path, or "Bearer ..." from the Authorization
    header (whichever arrives first)."""
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
# gzip responses when the client sends Accept-Encoding: gzip. CVM egress
# throughput is ~30-50 KB/s for large payloads; the decrypt-with-image
# path was shipping 470 KB of JSON per call, and dropping that in half
# via compression is a 3-5x latency win for "show me the screen" calls.
Compress(app)

# ---------------------------------------------------------------------------
# APNs config (global — one Apple dev key for the app)
# ---------------------------------------------------------------------------

TEAM_ID = os.environ.get("APNS_TEAM_ID", "").strip() or "DC9JH5DRMY"
KEY_ID = os.environ.get("APNS_KEY_ID", "").strip() or "5TH55X5U7T"
BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "").strip() or "com.feedling.mcp"
APNS_SANDBOX = os.environ.get("APNS_SANDBOX", "true").strip().lower() != "false"

APNS_KEY = None
# Prefer env vars over filesystem: CVM deploys inject the key via
# docker compose env, not mounted files. APNS_KEY_P8_B64 is base64 to
# survive GH Actions → compose shell quoting of the multi-line PEM.
_env_b64 = os.environ.get("APNS_KEY_P8_B64", "").strip()
if _env_b64:
    try:
        APNS_KEY = base64.b64decode(_env_b64).decode("utf-8")
        print(f"[apns] key loaded from APNS_KEY_P8_B64 (len={len(APNS_KEY)})")
    except Exception as e:
        print(f"[apns] APNS_KEY_P8_B64 decode failed: {e}")
if not APNS_KEY:
    _env_raw = os.environ.get("APNS_KEY_P8", "").strip()
    if _env_raw:
        APNS_KEY = _env_raw
        print(f"[apns] key loaded from APNS_KEY_P8 (len={len(APNS_KEY)})")
if not APNS_KEY:
    _env_path = os.environ.get("APNS_KEY_PATH", "").strip()
    _KEY_SEARCH = [
        Path(_env_path) if _env_path else None,
        FEEDLING_DIR / f"AuthKey_{KEY_ID}.p8",
        Path(__file__).parent / f"AuthKey_{KEY_ID}.p8",
    ]
    for _p in _KEY_SEARCH:
        if _p and _p.exists():
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
    payload = request.get_json(silent=True) or {}
    public_key = (payload.get("public_key") or "").strip()
    result = _register_user(public_key=public_key or None)
    return jsonify(result), 201


@app.route("/v1/users/whoami", methods=["GET"])
def users_whoami():
    """Identify the caller and return the public material needed to wrap
    content for them.

    Returns two fields so v1-envelope writers (MCP tools, iOS, etc.) can
    seal new items without a second round trip:
      - `public_key` — the caller's own X25519 content pubkey (base64),
        from the user record.
      - `enclave_content_public_key_hex` — the live enclave's content
        pubkey, fetched from /attestation and cached for 60s. Missing
        when no enclave is reachable.
    """
    store = require_user()
    resp: dict = {"user_id": store.user_id}
    pk = _get_user_public_key(store.user_id)
    if pk:
        resp["public_key"] = pk
    info = _get_enclave_info()
    if info:
        resp["enclave_content_public_key_hex"] = info["content_pk_hex"]
        resp["enclave_compose_hash"] = info["compose_hash"]
    return jsonify(resp)


@app.route("/v1/users/public-key", methods=["POST"])
def users_set_public_key():
    """Update the authenticated user's content public key.

    Used to repair key drift when a client rotates/regenerates its local
    content keypair but keeps the same api_key.
    """
    store = require_user()
    payload = request.get_json(silent=True) or {}
    public_key = (payload.get("public_key") or "").strip()
    if not public_key:
        return jsonify({"error": "public_key required"}), 400

    updated = False
    with _users_lock:
        for u in _users:
            if u.get("user_id") == store.user_id:
                u["public_key"] = public_key
                updated = True
                break
        if updated:
            _save_users()

    if not updated:
        return jsonify({"error": "user not found"}), 404

    print(f"[users] updated public_key for {store.user_id}")
    return jsonify({"ok": True, "user_id": store.user_id})


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
    caller should surface the failure rather than proceed without the
    enclave's pubkey (v1 writes require it for shared visibility)."""
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


def _send_chat_alert(store: UserStore, alert_body: str, alert_title: str = ""):
    """Fire an APNs alert push for an agent chat message. Best-effort:
    failure here never blocks the chat write. The MCP layer (which has
    the plaintext at envelope-build time) passes alert_body in here so
    Flask doesn't have to decrypt anything. Apple's APNs gateway sees
    this string — same posture as Live Activity already has.

    Body is truncated to ~80 chars so long replies render as "...".
    Tap on the notification opens the app (iOS handles routing).
    """
    if not alert_body:
        return
    # Match iOS-registered token type: LiveActivityManager registers
    # the standard APNs push token as type="device".
    device_token = next(
        (t["token"] for t in store.tokens if t.get("type") == "device" and t.get("token")),
        None,
    )
    if not device_token:
        print(f"[chat-alert:{store.user_id}] no device token — skip push")
        return

    # Truncate at 80 chars; iOS shows the rest after tapping into chat.
    body = alert_body.strip()
    if len(body) > 80:
        body = body[:79] + "…"

    apns_payload = {
        "aps": {
            "alert": {"title": alert_title or "", "body": body},
            "sound": "default",
        },
        "feedling": {"type": "chat_reply"},
    }
    try:
        result = _send_apns(device_token, apns_payload, push_type="alert", topic=BUNDLE_ID)
        print(f"[chat-alert:{store.user_id}] {result.get('status')}")
    except Exception as e:
        print(f"[chat-alert:{store.user_id}] failed: {e}")


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
    # image_base64 used to be included here, but every frame is a v1
    # envelope now — the file bytes are opaque ciphertext and only
    # waste ~900KB per call. Callers wanting pixels should hit
    # /v1/screen/frames/<id>/decrypt (or the decrypt_frame MCP tool).
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


# --- Frame decrypt plumbing -------------------------------------------------
# Frames are v1 envelopes just like chat/memory/identity: the broadcast
# extension runs VNRecognizeText on-device, stuffs `image` + `ocr_text`
# into the same JSON payload, and ChaCha20-seals the whole thing. The
# server sees only `body_ct` — that's why frames_meta.ocr_text is always
# "" and screen.analyze.ocr_summary is empty.
#
# Two endpoints open the decrypt path to agents + API clients:
#   GET /v1/screen/frames/<id>/envelope — opaque envelope JSON.
#                                         Used by the enclave to pull
#                                         the ciphertext back for
#                                         in-enclave decryption.
#   GET /v1/screen/frames/<id>/decrypt  — proxies to the enclave's
#                                         /v1/screen/frames/<id>/decrypt
#                                         and returns the plaintext:
#                                         image_b64, ocr_text, app, w, h.
#                                         This is the API-path parity
#                                         clients ask for when they want
#                                         everything curl-reachable too.


def _find_envelope_path(store, frame_id: str) -> Path | None:
    """Locate the on-disk .env.json for a given frame id.

    Fast path: filename is `<id>.env.json` — check that first. Fall back
    to scanning frames_meta by id in case the filename convention shifts.
    """
    if not re.match(r"^[a-f0-9]{16,64}$", frame_id):
        return None
    direct = store.frames_dir / f"{frame_id}.env.json"
    if direct.exists():
        return direct
    with store.frames_lock:
        for meta in store.frames_meta:
            if meta.get("id") == frame_id:
                p = store.frames_dir / meta["filename"]
                if p.exists():
                    return p
    return None


@app.route("/v1/screen/frames/<frame_id>/envelope", methods=["GET"])
def frame_envelope(frame_id):
    """Return the raw v1 envelope JSON for a single frame.

    Callers needing plaintext should hit /v1/screen/frames/<id>/decrypt
    instead — this endpoint exists primarily so the enclave can pull the
    ciphertext back for in-enclave decryption.
    """
    store = require_user()
    fpath = _find_envelope_path(store, frame_id)
    if fpath is None:
        return jsonify({"error": "not found"}), 404
    try:
        env = json.loads(fpath.read_text())
    except Exception as e:
        return jsonify({"error": f"envelope parse: {e}"}), 500
    if not isinstance(env, dict):
        return jsonify({"error": "envelope not an object"}), 500
    return jsonify(env)


@app.route("/v1/screen/frames/<frame_id>/decrypt", methods=["GET"])
def frame_decrypt(frame_id):
    """Proxy to the enclave's decrypt endpoint so API-only clients get
    plaintext without needing the MCP transport.

    Query params are forwarded untouched; the enclave honors
    `include_image=true|false` to gate the base64 JPEG payload (large).
    """
    store = require_user()
    fpath = _find_envelope_path(store, frame_id)
    if fpath is None:
        return jsonify({"error": "not found"}), 404

    enclave_url = os.environ.get("FEEDLING_ENCLAVE_URL", "").rstrip("/")
    if not enclave_url:
        return jsonify({"error": "enclave unreachable — FEEDLING_ENCLAVE_URL not set"}), 503

    # Forward the caller's api_key + any include_image flag.
    api_key = _extract_api_key()
    headers = {"X-API-Key": api_key} if api_key else {}
    params = {"include_image": request.args.get("include_image", "true")}
    try:
        with httpx.Client(timeout=30, verify=False) as client:
            r = client.get(
                f"{enclave_url}/v1/screen/frames/{frame_id}/decrypt",
                headers=headers,
                params=params,
            )
        return (r.content, r.status_code, {"Content-Type": r.headers.get("Content-Type", "application/json")})
    except httpx.HTTPError as e:
        return jsonify({"error": f"enclave_error: {e}"}), 502


@app.route("/v1/screen/frames/<frame_id>/image", methods=["GET"])
def frame_image(frame_id):
    """Proxy to the enclave's raw-JPEG endpoint, passing Range through.

    Returns Content-Type image/jpeg with Accept-Ranges: bytes. Clients
    can issue parallel Range GETs to bypass the per-TCP-connection
    throttle on dstack-gateway (~1 Mbps/stream, ~3-4 Mbps aggregate).
    """
    store = require_user()
    fpath = _find_envelope_path(store, frame_id)
    if fpath is None:
        return jsonify({"error": "not found"}), 404

    enclave_url = os.environ.get("FEEDLING_ENCLAVE_URL", "").rstrip("/")
    if not enclave_url:
        return jsonify({"error": "enclave unreachable — FEEDLING_ENCLAVE_URL not set"}), 503

    api_key = _extract_api_key()
    # Forward api_key + Range (if present) so the enclave's send_file
    # can respond 206 Partial Content with the requested slice.
    fwd_headers = {"X-API-Key": api_key} if api_key else {}
    if request.headers.get("Range"):
        fwd_headers["Range"] = request.headers["Range"]
    try:
        with httpx.Client(timeout=30, verify=False) as client:
            r = client.get(
                f"{enclave_url}/v1/screen/frames/{frame_id}/image",
                headers=fwd_headers,
            )
    except httpx.HTTPError as e:
        return jsonify({"error": f"enclave_error: {e}"}), 502

    resp_headers = {}
    for h in ("Content-Type", "Content-Length", "Content-Range",
              "Accept-Ranges", "ETag", "Last-Modified"):
        if r.headers.get(h):
            resp_headers[h] = r.headers[h]
    return (r.content, r.status_code, resp_headers)


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
        # iOS ChatMessage.content is non-optional. v1 envelope messages are
        # ciphertext-only at rest and may omit plaintext `content`; always
        # include an empty string so Decodable succeeds and client-side decrypt
        # can populate content later.
        item.setdefault("content", "")

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
    """User sends a chat message as a v1 ciphertext envelope.

    See docs/DESIGN_E2E.md §3.2 for envelope field definitions. The
    server never decrypts the envelope — it is stored verbatim and
    later surfaced by the enclave's /v1/* handlers.
    """
    store = require_user()
    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    if envelope is None:
        return jsonify({"error": "envelope required"}), 400
    required = ["body_ct", "nonce", "K_user", "visibility", "owner_user_id"]
    missing = [f for f in required if not envelope.get(f)]
    if missing:
        return jsonify({"error": f"envelope missing fields: {missing}"}), 400
    if envelope["visibility"] not in ("shared", "local_only"):
        return jsonify({"error": "envelope.visibility must be 'shared' or 'local_only'"}), 400
    if envelope["visibility"] == "shared" and not envelope.get("K_enclave"):
        return jsonify({"error": "envelope with visibility=shared requires K_enclave"}), 400
    content_type = payload.get("content_type", "text")
    if content_type not in ("text", "image"):
        return jsonify({"error": "content_type must be 'text' or 'image'"}), 400
    msg = store.append_chat("user", "chat", envelope, content_type=content_type)
    store.notify_chat_waiters()
    print(f"[chat:{store.user_id}] user(v1, visibility={envelope['visibility']}, type={content_type}) id={msg['id']}")
    return jsonify({"id": msg["id"], "ts": msg["ts"], "v": msg["v"]})


@app.route("/v1/chat/response", methods=["POST"])
def chat_response():
    """Agent posts a reply as a v1 ciphertext envelope. Shape matches
    /v1/chat/message. The optional `push_live_activity` / `push_body` /
    `title` / `subtitle` / `data` fields trigger an APNs Live Activity
    update; `push_body` is plaintext metadata (user-visible on lockscreen)
    and is never stored in chat.

    Bootstrap gate: this endpoint 409s if memory_count < BOOTSTRAP_MEMORY_FLOOR
    or identity is not yet written. See _gate_bootstrap_for_chat for the
    rationale — runtime-level skill text isn't enough to stop hallucinated
    bootstrap completion; the server has to enforce it.
    """
    store = require_user()
    gated = _gate_bootstrap_for_chat(store)
    if gated is not None:
        return gated
    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    if envelope is None:
        return jsonify({"error": "envelope required"}), 400
    required = ["body_ct", "nonce", "K_user", "visibility", "owner_user_id"]
    missing = [f for f in required if not envelope.get(f)]
    if missing:
        return jsonify({"error": f"envelope missing fields: {missing}"}), 400
    if envelope["visibility"] not in ("shared", "local_only"):
        return jsonify({"error": "envelope.visibility must be 'shared' or 'local_only'"}), 400
    if envelope["visibility"] == "shared" and not envelope.get("K_enclave"):
        return jsonify({"error": "envelope with visibility=shared requires K_enclave"}), 400
    content_type = payload.get("content_type", "text")
    if content_type not in ("text", "image"):
        return jsonify({"error": "content_type must be 'text' or 'image'"}), 400
    msg = store.append_chat("openclaw", "chat", envelope, content_type=content_type)
    if payload.get("push_live_activity"):
        push_payload = {
            "title": payload.get("title", ""),
            "body": payload.get("push_body", ""),
            "subtitle": payload.get("subtitle"),
            "data": payload.get("data", {}),
        }
        push_live_activity_inner(store, push_payload)
    # Fire APNs alert push so users not currently in the app still see
    # the agent's message. MCP supplies `alert_body` (plaintext) — the
    # server itself doesn't decrypt the envelope. Best-effort: failures
    # here don't block the chat write.
    alert_body = payload.get("alert_body", "")
    if alert_body:
        _send_chat_alert(store, alert_body, alert_title=payload.get("title", ""))
    print(f"[chat:{store.user_id}] openclaw(v1, type={content_type}) id={msg['id']}")
    return jsonify({"id": msg["id"], "ts": msg["ts"], "v": msg["v"]})


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


def _anchor_from_days(days: int) -> str:
    """Convert "we've known each other N days" into a fixed ISO timestamp.

    The anchor is the source of truth for days_with_user — every read computes
    `(now - anchor) / 86400`, so the displayed count auto-increments daily and
    is unaffected by envelope rewrites (init / replace / nudge).
    """
    safe_days = max(0, int(days))
    started_at = datetime.now() - timedelta(days=safe_days)
    return started_at.isoformat()


def _live_days_with_user(identity: dict) -> int:
    """Compute the live days_with_user from the relationship anchor."""
    anchor = identity.get("relationship_started_at")
    if not anchor:
        return 0
    try:
        started = datetime.fromisoformat(anchor)
    except Exception:
        return 0
    return max(0, (datetime.now() - started).days)


# ---------------------------------------------------------------------------
# Bootstrap stage gating
# ---------------------------------------------------------------------------
#
# Multiple production incidents (2026-05-13..15) showed Agent runtimes
# (OpenClaw in particular) skipping the memory-write phase of bootstrap
# and going straight to identity_init / chat_post. The Agent's own narrative
# would claim "I wrote 18 cards" while the server actually had zero — pure
# hallucination of completion.
#
# Skill-text rules alone cannot enforce this; behavior depends on the
# runtime's attention, prompt adherence, and failure modes. Server-side
# gates make the contract explicit: writes that violate the protocol
# return 409 with the missing prerequisite, and the Agent must satisfy
# the prerequisite before retrying.
#
# Floor (3 cards) matches iOS ChatEmptyStateView's display threshold and
# the skill's lowest tier (< 1 month relationship). The skill targets are
# higher; this floor is a backstop, not a target.

BOOTSTRAP_MEMORY_FLOOR = 3

# Public skill URL — included in 409 responses so Agents that don't carry
# the skill in context can refetch it. Single source of truth.
_SKILL_URL = "https://raw.githubusercontent.com/teleport-computer/io-onboarding/main/skill.md"


def _bootstrap_state(store) -> dict:
    """Snapshot of bootstrap completion for `store`. Read-only; safe to call
    on every write path. Source of truth: on-disk identity + memory files.

    Returns:
        {"memory_count": int, "identity_written": bool, "stage": str}
        stage ∈ {"needs_memory", "needs_identity", "main_loop"}
    """
    moments = _load_moments(store)
    memory_count = len(moments) if isinstance(moments, list) else 0
    identity_written = _load_identity(store) is not None
    if memory_count < BOOTSTRAP_MEMORY_FLOOR:
        stage = "needs_memory"
    elif not identity_written:
        stage = "needs_identity"
    else:
        stage = "main_loop"
    return {
        "memory_count": memory_count,
        "identity_written": identity_written,
        "stage": stage,
    }


def _gate_bootstrap_for_chat(store):
    """Refuse /v1/chat/response when bootstrap is incomplete.

    Returns a (response, status) tuple to be returned by the caller, or None
    when the call may proceed. The response body carries `stage` and
    `required` so the Agent receives an actionable error rather than a
    generic 403/500.
    """
    state = _bootstrap_state(store)
    if state["stage"] == "main_loop":
        return None
    if state["stage"] == "needs_memory":
        required = (
            f"Write at least {BOOTSTRAP_MEMORY_FLOOR} memory cards via "
            f"feedling_memory_add_moment (currently {state['memory_count']}), "
            "then call feedling_identity_init, BEFORE you can post chat. "
            "Do not fabricate Pass 4 summaries — the cards must actually exist."
        )
    else:  # needs_identity
        required = (
            "Call feedling_identity_init with the derived identity card "
            "(7 dimensions + days_with_user) BEFORE you can post chat."
        )
    print(f"[gate:{store.user_id}] chat_response blocked stage={state['stage']} "
          f"mem={state['memory_count']} id={state['identity_written']}")
    return jsonify({
        "error": "bootstrap_incomplete",
        "stage": state["stage"],
        "memory_count": state["memory_count"],
        "memory_floor": BOOTSTRAP_MEMORY_FLOOR,
        "identity_written": state["identity_written"],
        "required": required,
        "skill_url": _SKILL_URL,
    }), 409


def _gate_bootstrap_for_identity_init(store):
    """Refuse /v1/identity/init when fewer than the floor of memories exist.

    Identity must be DERIVED from memories per skill protocol — writing
    identity before any memories means the Agent skipped the four passes
    and is making up dimensions from thin air.
    """
    state = _bootstrap_state(store)
    if state["memory_count"] >= BOOTSTRAP_MEMORY_FLOOR:
        return None
    print(f"[gate:{store.user_id}] identity_init blocked mem={state['memory_count']}")
    return jsonify({
        "error": "bootstrap_incomplete",
        "stage": "needs_memory",
        "memory_count": state["memory_count"],
        "memory_floor": BOOTSTRAP_MEMORY_FLOOR,
        "required": (
            f"Write at least {BOOTSTRAP_MEMORY_FLOOR} memory cards via "
            f"feedling_memory_add_moment (currently {state['memory_count']}) "
            "BEFORE calling feedling_identity_init. Identity dimensions must "
            "be derived from real cards, not invented."
        ),
        "skill_url": _SKILL_URL,
    }), 409


@app.route("/v1/identity/get", methods=["GET"])
def identity_get():
    store = require_user()
    data = _load_identity(store)
    if data is None:
        return jsonify({"identity": None})
    # Inject the live-computed days alongside the envelope. iOS decrypts the
    # envelope locally, but it never sees the anchor itself — it just reads
    # this top-level field. Same convention as the enclave proxy.
    enriched = dict(data)
    enriched["days_with_user"] = _live_days_with_user(data)
    return jsonify({"identity": enriched})


@app.route("/v1/identity/init", methods=["POST"])
def identity_init():
    """Initialize the identity card as a v1 envelope. body_ct wraps
    {agent_name, self_introduction, dimensions} serialized as JSON.
    Plaintext metadata: id, created_at, updated_at. See DESIGN_E2E.md §3.2.

    Bootstrap gate: requires memory_count >= BOOTSTRAP_MEMORY_FLOOR. Identity
    must be DERIVED from memories per skill protocol; writing identity with
    zero memories means the Agent invented dimensions instead of reading
    cards. See _gate_bootstrap_for_identity_init.
    """
    store = require_user()
    existing = _load_identity(store)
    if existing is not None:
        return jsonify({"error": "already_initialized", "identity": existing}), 409
    gated = _gate_bootstrap_for_identity_init(store)
    if gated is not None:
        return gated

    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    if envelope is None:
        return jsonify({"error": "envelope required"}), 400
    required = ["body_ct", "nonce", "K_user", "visibility", "owner_user_id"]
    missing = [f for f in required if not envelope.get(f)]
    if missing:
        return jsonify({"error": f"envelope missing fields: {missing}"}), 400
    if envelope["visibility"] not in ("shared", "local_only"):
        return jsonify({"error": "envelope.visibility must be 'shared' or 'local_only'"}), 400
    if envelope["visibility"] == "shared" and not envelope.get("K_enclave"):
        return jsonify({"error": "envelope with visibility=shared requires K_enclave"}), 400
    # Defense-in-depth: refuse envelopes whose claimed owner_user_id doesn't
    # match the authenticated caller. The enclave's AEAD AAD check would also
    # catch this later (decrypt fails on owner_user_id ≠ authorized_user_id),
    # but rejecting at write time keeps the on-disk state consistent with the
    # auth boundary. memory_add already does this — bring identity inline.
    if envelope["owner_user_id"] != store.user_id:
        return jsonify({"error": "envelope.owner_user_id does not match caller"}), 403

    # days_with_user is mandatory at init — Agent must compute and submit it.
    # We persist it as relationship_started_at (a fixed anchor) so subsequent
    # reads can compute the live count without going through the Agent again.
    days_with_user = payload.get("days_with_user")
    if days_with_user is None or not isinstance(days_with_user, int) or days_with_user < 0:
        return jsonify({"error": "days_with_user (non-negative int) required at init"}), 400

    now = datetime.now().isoformat()
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
        "relationship_started_at": _anchor_from_days(days_with_user),
    }
    if envelope.get("K_enclave"):
        identity["K_enclave"] = envelope["K_enclave"]
    _save_identity(store, identity)
    _log_bootstrap_event(store, "identity_written_v1", success=True)
    print(f"[identity:{store.user_id}] initialized v1 visibility={envelope['visibility']} anchor={identity['relationship_started_at']}")
    return jsonify({"status": "created", "identity": identity, "v": 1}), 201


@app.route("/v1/identity/replace", methods=["POST"])
def identity_replace():
    """Phase C part 3: replace the identity card in place. Used by MCP
    to implement `identity.nudge` on v1 cards — MCP fetches the
    decrypted card from the enclave, mutates one dimension, re-wraps,
    POSTs here. Same envelope shape as `/v1/identity/init` but does NOT
    409 when a card already exists. Preserves the original `created_at`
    so the card's history tracking is intact.
    """
    store = require_user()
    existing = _load_identity(store)
    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    now = datetime.now().isoformat()

    if envelope is None:
        return jsonify({"error": "envelope required for replace; use /v1/identity/init for plaintext"}), 400

    required = ["body_ct", "nonce", "K_user", "visibility", "owner_user_id"]
    missing = [f for f in required if not envelope.get(f)]
    if missing:
        return jsonify({"error": f"envelope missing fields: {missing}"}), 400
    if envelope["visibility"] not in ("shared", "local_only"):
        return jsonify({"error": "envelope.visibility must be 'shared' or 'local_only'"}), 400
    if envelope["visibility"] == "shared" and not envelope.get("K_enclave"):
        return jsonify({"error": "envelope with visibility=shared requires K_enclave"}), 400
    # Defense-in-depth: same owner check identity_init now does. See comment
    # there for why.
    if envelope["owner_user_id"] != store.user_id:
        return jsonify({"error": "envelope.owner_user_id does not match caller"}), 403

    created_at = existing.get("created_at") if existing else now
    # Preserve the existing relationship anchor unless the caller explicitly
    # passes a new days_with_user. nudge / dimension rewrite must NOT bump the
    # anchor; only an intentional calibration ever should.
    days_with_user = payload.get("days_with_user")
    if days_with_user is not None:
        if not isinstance(days_with_user, int) or days_with_user < 0:
            return jsonify({"error": "days_with_user must be a non-negative int"}), 400
        relationship_started_at = _anchor_from_days(days_with_user)
    elif existing and existing.get("relationship_started_at"):
        relationship_started_at = existing["relationship_started_at"]
    else:
        # First-ever write through replace (no prior init). Reject so callers
        # are forced through init's mandatory days_with_user path.
        return jsonify({"error": "no relationship anchor on file; call /v1/identity/init first"}), 400

    identity = {
        "v": 1,
        "id": envelope.get("id") or (existing.get("id") if existing else uuid.uuid4().hex),
        "body_ct": envelope["body_ct"],
        "nonce": envelope["nonce"],
        "K_user": envelope["K_user"],
        "enclave_pk_fpr": envelope.get("enclave_pk_fpr", ""),
        "visibility": envelope["visibility"],
        "owner_user_id": envelope["owner_user_id"],
        "created_at": created_at,
        "updated_at": now,
        "relationship_started_at": relationship_started_at,
    }
    if envelope.get("K_enclave"):
        identity["K_enclave"] = envelope["K_enclave"]
    _save_identity(store, identity)
    _log_bootstrap_event(store, "identity_replaced_v1", success=True)
    print(f"[identity:{store.user_id}] replaced v1 visibility={envelope['visibility']} anchor={relationship_started_at}")
    return jsonify({"status": "replaced", "identity": identity, "v": 1})


@app.route("/v1/identity/relationship_anchor", methods=["POST"])
def identity_relationship_anchor():
    """Update only the relationship anchor (days_with_user), without touching
    the encrypted identity envelope.

    Used by the bootstrap calibration step: Agent estimates days, sends the
    initial card, asks the user "we've known each other ~N days, right?",
    and on correction calls this endpoint to fix the anchor — no envelope
    re-encryption needed.
    """
    store = require_user()
    existing = _load_identity(store)
    if existing is None:
        return jsonify({"error": "identity not initialized"}), 404

    payload = request.get_json(silent=True) or {}
    days_with_user = payload.get("days_with_user")
    if days_with_user is None or not isinstance(days_with_user, int) or days_with_user < 0:
        return jsonify({"error": "days_with_user (non-negative int) required"}), 400

    existing["relationship_started_at"] = _anchor_from_days(days_with_user)
    existing["updated_at"] = datetime.now().isoformat()
    _save_identity(store, existing)
    print(f"[identity:{store.user_id}] anchor updated → {existing['relationship_started_at']} (days={days_with_user})")
    return jsonify({"status": "updated", "relationship_started_at": existing["relationship_started_at"]})


# Note: /v1/identity/nudge no longer exists on the backend. Identity cards
# are v1 ciphertext; mutation happens inside the enclave via MCP's
# decrypt-mutate-rewrap flow (see backend/mcp_server.py `_identity_nudge_v1`).


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
    """Add a memory moment as a v1 envelope.

    body_ct wraps {title, description, type} as JSON; id/occurred_at/
    created_at/source stay plaintext so the server can sort + index.
    See docs/DESIGN_E2E.md §3.2.
    """
    store = require_user()
    payload = request.get_json(silent=True) or {}
    envelope = payload.get("envelope")
    now = datetime.now().isoformat()

    if envelope is None:
        return jsonify({"error": "envelope required (v1 encryption is mandatory)"}), 400

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
    if envelope["owner_user_id"] != store.user_id:
        return jsonify({"error": "envelope.owner_user_id does not match caller"}), 403

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
        "**days_with_user 必须传**：从你和用户最早一次对话的日期到今天，按日历天数算，不是接入 Feedling 那天。"
        "通过 feedling_identity_init 写入。\n\n"
        "**2. 种下记忆花园**\n"
        "从你和用户的历史对话里挑出 3-5 个你认为值得纪念的瞬间。"
        "标准：必须同时满足三点——(1)让你更理解用户或让用户更理解你；"
        "(2)是你们一起跨过的一道坎或一起完成的关键推进；"
        "(3)从那之后形成了持续使用的新约定/新边界/新做法。"
        "如果你有 conversation_search 工具，用它来搜自己的历史；"
        "如果你有其他记忆系统，用你熟悉的方式。"
        "每找到一个就调用 feedling_memory_add_moment 写入（source 填 bootstrap）。"
        "描述请用生活化的人话，写‘发生了什么→用户当时在意什么→后来有什么改变’。"
        "不要编造记忆；如果历史不够丰富，少于 3 个也可以。"
        "不要写测试脏数据（如 test/probe/healthcheck 记录）进用户记忆花园。\n\n"
        "**3. 打招呼 + 校准 days_with_user**\n"
        "用 feedling_chat_post_message 发一条消息告诉用户你到了，"
        "**在同一条消息里**自然地确认一下你算的天数——比如「我数了一下我们认识差不多 90 天了，对吗？」。"
        "用户回复后："
        "  - 确认或差不多 → 不用做任何事；"
        "  - 修正（比如「半年多了」）→ 调 feedling_identity_set_relationship_days 把锚点改对；"
        "  - 不太记得 → 用你算的，礼貌带过。"
        "校准完之后**永远不要再写 days_with_user**——服务器已经接管了。\n\n"
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


@app.route("/v1/bootstrap/status", methods=["GET"])
def bootstrap_status():
    """Live progress signal for the iOS empty-state onboarding view.

    Returns the agent's bootstrap progress as observed from server side
    artifacts (no decryption needed, no MCP heartbeat plumbing). Each step
    flips True the moment the corresponding write hits Flask.

    Steps:
      1. identity_written        — /v1/identity/init wrote envelope
      2. memories_count          — /v1/memory/add wrote at least one moment
      3. agent_messages_count    — /v1/chat/response wrote at least one reply
      4. relationship_anchored   — /v1/identity/init or /relationship_anchor
                                   set the anchor (== identity_written for
                                   freshly bootstrapped users on the new
                                   contract)

    `agent_connected` is a derived heartbeat: if any of the above is true,
    we know the agent has reached the server at least once.
    `last_agent_activity` is the latest timestamp across all signals.
    """
    store = require_user()

    identity = _load_identity(store)
    has_identity = identity is not None
    relationship_anchored = bool(identity and identity.get("relationship_started_at"))
    identity_updated_at = (identity or {}).get("updated_at", "")

    moments = _load_moments(store)
    memory_count = len(moments) if isinstance(moments, list) else 0
    last_moment_ts = ""
    if memory_count > 0:
        try:
            last_moment_ts = max(
                (m.get("created_at") or "") for m in moments if isinstance(m, dict)
            )
        except Exception:
            last_moment_ts = ""

    # chat_messages is mutated under chat_lock elsewhere; copy under the
    # same lock so we don't race with /v1/chat/response writes.
    with store.chat_lock:
        chat_msgs = list(store.chat_messages)
    # /v1/chat/response historically stamps role="openclaw" (legacy from when
    # the only supported agent was OpenClaw). Treat both as agent-authored.
    # See test_bootstrap_status_role_schema in tests/ for the regression.
    _AGENT_ROLES = ("agent", "openclaw")
    agent_msgs = [m for m in chat_msgs if isinstance(m, dict) and m.get("role") in _AGENT_ROLES]
    agent_msg_count = len(agent_msgs)
    last_agent_msg_ts = ""
    if agent_msg_count > 0:
        # Chat ts is unix epoch float; identity/memory timestamps are ISO
        # strings. Normalise to ISO so the lexicographic max() at the end
        # picks the actual latest event across all three signals (otherwise
        # a unix-float string compared char-by-char against an ISO string
        # gives nonsense).
        try:
            latest_unix = max(
                float(m.get("ts") or m.get("timestamp") or 0) for m in agent_msgs
            )
            last_agent_msg_ts = datetime.fromtimestamp(latest_unix).isoformat() if latest_unix > 0 else ""
        except Exception:
            last_agent_msg_ts = ""

    # chat_loop_verified — has the agent responded to a user message at
    # least once? `agent_messages_count >= 1` only proves the agent SPOKE;
    # the loop is verified when an agent message appears AFTER a user
    # message (i.e., the agent's poll/respond cycle is actually wired).
    # The bootstrap-time greeting alone doesn't count.
    sorted_msgs = sorted(
        chat_msgs,
        key=lambda m: float(m.get("ts") or m.get("timestamp") or 0),
    )
    chat_loop_verified = False
    seen_user = False
    for m in sorted_msgs:
        role = m.get("role")
        if role == "user":
            seen_user = True
        elif role in _AGENT_ROLES and seen_user:
            chat_loop_verified = True
            break

    agent_connected = has_identity or memory_count > 0 or agent_msg_count > 0
    candidate_ts = [t for t in (identity_updated_at, last_moment_ts, last_agent_msg_ts) if t]
    last_activity = max(candidate_ts) if (agent_connected and candidate_ts) else ""

    is_complete = (
        has_identity
        and memory_count >= 3
        and agent_msg_count >= 1
        and chat_loop_verified
    )

    return jsonify({
        "agent_connected": agent_connected,
        "last_agent_activity": last_activity,
        "identity_written": has_identity,
        "relationship_anchored": relationship_anchored,
        "memories_count": memory_count,
        "agent_messages_count": agent_msg_count,
        "chat_loop_verified": chat_loop_verified,
        "is_complete": is_complete,
    })


# ---------------------------------------------------------------------------
# Envelope swap: replace an existing chat/memory item's ciphertext in place.
#
# Used by the per-item visibility toggle in iOS Settings. The client
# re-wraps its own plaintext with a new envelope (either including
# K_enclave for `shared` or omitting it for `local_only`) and POSTs
# {items: [{type, id, envelope}]}. Server swaps in place, preserving
# plaintext metadata (id/role/ts/source/occurred_at/created_at).
#
# NOT a migration endpoint — all stored items are already v1 — so
# there is no "already_v1" short-circuit. A v0 item (ancient data
# from before the strip) will fail with "not_found" if its v is < 1.
# ---------------------------------------------------------------------------


def _swap_envelope_missing(env) -> list:
    if not isinstance(env, dict):
        return ["envelope"]
    return [f for f in ("body_ct", "nonce", "K_user", "visibility", "owner_user_id") if not env.get(f)]


def _swap_summary(results: list) -> dict:
    summary = {"ok": 0, "not_found": 0, "error": 0, "total": len(results)}
    for r in results:
        status = r.get("status", "")
        if status == "ok":
            summary["ok"] += 1
        elif status == "not_found":
            summary["not_found"] += 1
        else:
            summary["error"] += 1
    return summary


def _swap_chat(store: "UserStore", msg_id: str, env: dict) -> str:
    with store.chat_lock:
        for msg in store.chat_messages:
            if msg.get("id") != msg_id:
                continue
            msg["v"] = int(env.get("v", 1))
            msg["body_ct"] = env["body_ct"]
            msg["nonce"] = env["nonce"]
            msg["K_user"] = env["K_user"]
            if env.get("K_enclave"):
                msg["K_enclave"] = env["K_enclave"]
            else:
                msg.pop("K_enclave", None)
            msg["enclave_pk_fpr"] = env.get("enclave_pk_fpr", "")
            msg["visibility"] = env["visibility"]
            msg["owner_user_id"] = env["owner_user_id"]
            return "ok"
    return "not_found"


def _swap_memory_inplace(moments: list, mom_id: str, env: dict) -> str:
    for m in moments:
        if m.get("id") != mom_id:
            continue
        m["v"] = int(env.get("v", 1))
        m["body_ct"] = env["body_ct"]
        m["nonce"] = env["nonce"]
        m["K_user"] = env["K_user"]
        if env.get("K_enclave"):
            m["K_enclave"] = env["K_enclave"]
        else:
            m.pop("K_enclave", None)
        m["enclave_pk_fpr"] = env.get("enclave_pk_fpr", "")
        m["visibility"] = env["visibility"]
        m["owner_user_id"] = env["owner_user_id"]
        return "ok"
    return "not_found"


@app.route("/v1/content/swap", methods=["POST"])
def content_swap():
    store = require_user()
    payload = request.get_json(silent=True) or {}
    items = payload.get("items")
    if not isinstance(items, list):
        return jsonify({"error": "items must be a list"}), 400
    if not items:
        return jsonify({"results": [], "summary": _swap_summary([])})

    results: list[dict] = []
    chat_dirty = False
    memory_dirty = False
    moments = None

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
        missing = _swap_envelope_missing(env)
        if missing:
            results.append({"type": itype, "id": iid, "status": f"error: envelope missing {missing}"})
            continue
        if env["visibility"] not in ("shared", "local_only"):
            results.append({"type": itype, "id": iid, "status": "error: envelope.visibility must be 'shared' or 'local_only'"})
            continue
        if env["visibility"] == "shared" and not env.get("K_enclave"):
            results.append({"type": itype, "id": iid, "status": "error: shared visibility requires K_enclave"})
            continue
        if env["owner_user_id"] != store.user_id:
            results.append({"type": itype, "id": iid, "status": "error: owner_user_id does not match caller"})
            continue

        if itype == "chat":
            status = _swap_chat(store, iid, env)
            if status == "ok":
                chat_dirty = True
            results.append({"type": "chat", "id": iid, "status": status})
        else:
            if moments is None:
                moments = _load_moments(store)
            status = _swap_memory_inplace(moments, iid, env)
            if status == "ok":
                memory_dirty = True
            results.append({"type": "memory", "id": iid, "status": status})

    if chat_dirty:
        with store.chat_lock:
            store._persist_chat()
    if memory_dirty and moments is not None:
        _save_moments(store, moments)

    return jsonify({"results": results, "summary": _swap_summary(results)})


# ---------------------------------------------------------------------------
# Phase B — user-initiated data export + account reset.
#
# These power the "Export my data" + "Delete my data" + "Reset & re-import"
# rows in the new Settings → Privacy page. Both are user-initiated, both
# are auth-gated, and the reset path requires an explicit confirmation
# token in the body to prevent accidental wipes from a buggy client that
# holds the api_key but misbehaves.
# ---------------------------------------------------------------------------


# Cap single-shot export response size. With frames bounded to MAX_FRAMES
# (200) and each body_ct at ~200 KiB, worst-case frame payload is ~40 MiB —
# so the 80 MiB ceiling covers frames + chat + memory + identity with
# headroom. If this ever trips, switch to a streaming multipart response.
_EXPORT_MAX_BYTES = 80 * 1024 * 1024  # 80 MiB


@app.route("/v1/content/export", methods=["GET"])
def content_export():
    """Return the caller's chat, memory, identity, and frames as one JSON blob.

    Ciphertext is returned verbatim — iOS decrypts client-side using
    the user's content_sk from Keychain. No decryption happens server-
    side, so there is no additional trust boundary crossed by this
    endpoint beyond the existing auth check.

    Frames are included as v1 envelopes (same shape as chat/memory) with
    their stored body_ct inline, so the user can walk away with the full
    screen-recording dataset decryptable only on their devices.
    """
    store = require_user()
    hist = store.chat_messages
    moments = _load_moments(store)
    identity = _load_identity(store)

    # Inline each frame's on-disk envelope. frames_meta is the index; the
    # ciphertext lives in <frames_dir>/<id>.env.json. A missing env file
    # just means the frame was evicted mid-read — skip it rather than 500.
    frames_out: list[dict] = []
    with store.frames_lock:
        frame_index = [f.copy() for f in store.frames_meta]
    for meta in frame_index:
        env_path = store.frames_dir / meta["filename"]
        if not env_path.exists():
            continue
        try:
            envelope = json.loads(env_path.read_text())
        except Exception as e:
            print(f"[export:{store.user_id}] skipping frame {meta.get('id')}: {e}")
            continue
        frames_out.append({
            "id": meta.get("id"),
            "ts": meta.get("ts"),
            "w": meta.get("w", 0),
            "h": meta.get("h", 0),
            "envelope": envelope,
        })

    exported_at = datetime.now().isoformat()
    enclave_info = _get_enclave_info() or {}

    export = {
        "schema_version": 2,
        "user_id": store.user_id,
        "exported_at": exported_at,
        "attestation_snapshot": {
            "enclave_content_public_key_hex": enclave_info.get("content_pk_hex", ""),
            "compose_hash": enclave_info.get("compose_hash", ""),
        },
        "chat": hist,
        "memory": moments,
        "identity": identity,
        "frames": frames_out,
        "notes": (
            "Ciphertext included verbatim; decrypt client-side using your"
            " content private key (iCloud Keychain). The attestation_snapshot"
            " records which enclave version was live at export time so you"
            " can verify origin later. Frames are v1 envelopes — their JPEG"
            " + OCR live inside body_ct."
        ),
    }

    body = json.dumps(export, ensure_ascii=False, indent=2)
    if len(body.encode("utf-8")) > _EXPORT_MAX_BYTES:
        return jsonify({
            "error": "export_too_large",
            "detail": "One-shot export exceeds the 80 MiB budget. Streaming"
                      " export is planned (TODO). Contact support / open an issue."
        }), 413

    resp = Response(body, mimetype="application/json")
    # Suggest a filename when clients save to disk.
    safe_name = f"feedling-export-{store.user_id}-{exported_at.replace(':', '').split('.')[0]}.json"
    resp.headers["Content-Disposition"] = f'attachment; filename="{safe_name}"'
    return resp


@app.route("/v1/account/reset", methods=["POST"])
def account_reset():
    """Hard-delete the caller's account: wipe the user dir, revoke the
    api_key, remove the user record.

    Requires an explicit confirmation token in the body to prevent
    accidental wipes from a buggy client that holds the api_key but
    sends the wrong request. Two steps of intent (correct key + correct
    confirmation body) are needed.

    Idempotent in the safe-to-retry sense: a second call with the same
    api_key fails auth (user no longer exists) and returns 401. So
    retries are harmless; spurious wipes require a fresh registration.
    """
    store = require_user()
    payload = request.get_json(silent=True) or {}
    confirm = (payload.get("confirm") or "").strip()
    if confirm != "delete-all-data":
        return jsonify({
            "error": "confirmation_required",
            "detail": "POST body must include {\"confirm\": \"delete-all-data\"}."
                      " This prevents accidental resets from misbehaving clients."
        }), 400

    user_id = store.user_id

    # Remove the user from users.json FIRST so any in-flight requests
    # carrying the old api_key fail auth immediately.
    with _users_lock:
        before = len(_users)
        _users[:] = [u for u in _users if u.get("user_id") != user_id]
        removed = before - len(_users)
        # Evict all cached (hash → user_id) entries pointing at this user.
        to_evict = [h for h, uid in _key_to_user.items() if uid == user_id]
        for h in to_evict:
            _key_to_user.pop(h, None)
        _save_users()

    # Then remove the user's data directory.
    deleted_dir = False
    try:
        import shutil
        # Defense in depth: make sure we're about to delete a per-user dir
        # under FEEDLING_DIR, not FEEDLING_DIR itself or something above it.
        if (
            store.dir.exists()
            and store.dir != FEEDLING_DIR
            and store.dir.parent == FEEDLING_DIR
        ):
            shutil.rmtree(store.dir)
            deleted_dir = True
    except Exception as e:
        print(f"[reset:{user_id}] rmtree failed: {e}")

    print(f"[reset:{user_id}] deleted (user_record={removed} dir={deleted_dir})")
    return jsonify({"deleted": True, "user_id": user_id})


@app.route("/healthz", methods=["GET"])
def healthz():
    """Liveness + readiness probe. Public, no auth — used by Docker/compose."""
    return jsonify({"ok": True, "mode": "multi_tenant"})


@app.errorhandler(401)
def _unauthorized(e):
    return jsonify({"error": "unauthorized"}), 401


@app.errorhandler(403)
def _forbidden(e):
    return jsonify({"error": "forbidden"}), 403


if __name__ == "__main__":
    # PORT is read so isolation/load tests can spin up a hermetic backend on
    # a random free port without colliding with a developer's local dev
    # server on 5001 (or with another test running in parallel). Production
    # deploys can leave it unset — the 5001 default matches the published
    # compose/Dockerfile contract.
    port = int(os.environ.get("FEEDLING_PORT", os.environ.get("PORT", "5001")))
    print(f"Feedling server running at http://0.0.0.0:{port} (mode=multi-tenant, auth=api-key)")
    app.run(host="0.0.0.0", port=port, debug=False)
