#!/usr/bin/env python3
"""
Feedling MCP Server — SSE transport with per-connection API keys.

Architecture:
  Claude.ai / Claude Desktop / OpenClaw  →  mcp_server.py  →  app.py

Connection string (multi-tenant hosted mode):
    claude mcp add feedling --transport sse "https://mcp.feedling.app/sse?key=<api_key>"

The `?key=` query parameter is read by an ASGI middleware on every incoming
HTTP request (both the SSE GET and the tool-call POSTs) and cached against the
current MCP session_id. Each tool invocation reads the key back and forwards
it as `X-API-Key` to the Flask backend, which performs the actual bcrypt-style
user lookup.

Self-hosted mode: set `FEEDLING_API_KEY=<shared>` on both the backend and this
process. The backend still requires an api_key on every request — there is no
unauthenticated fallback.
"""

import base64
import json
import os
import re
import tempfile
import threading
from typing import Any

import httpx
from fastmcp import FastMCP, Context
from fastmcp.server.dependencies import get_http_request
from fastmcp.utilities.types import Image
from fastmcp.server.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.types import ASGIApp

from content_encryption import build_envelope

FLASK_BASE = os.environ.get("FEEDLING_FLASK_URL", "http://127.0.0.1:5001")
# When set, MCP routes content reads (chat history, memory list,
# identity get) through the enclave's decrypt endpoints so agents see
# plaintext rather than opaque ciphertext envelopes.
# verify=False on these calls because the enclave's TLS cert is
# self-signed; trust is REPORT_DATA-pinned from outside, not a PKI
# property of the in-cluster hop.
ENCLAVE_BASE = os.environ.get("FEEDLING_ENCLAVE_URL", "").rstrip("/")
FALLBACK_API_KEY = os.environ.get("FEEDLING_API_KEY", "").strip()

# ---------------------------------------------------------------------------
# Session-id → api_key cache
# ---------------------------------------------------------------------------
# MCP SSE clients open the event stream with `GET /sse?key=xxx`, then POST tool
# calls to `/messages/?session_id=yyy`. Different clients behave differently:
#   - Some forward `?key=` onto every subsequent POST URL.
#   - Some support `Authorization: Bearer <key>` headers end-to-end.
#
# Clients in the third historical category — "forward `?key=` only on the
# initial GET, then nothing on POSTs" — used to be supported via a fallback
# that looked up any pending key from the same `request.client.host`. That
# fallback was a P0 data-isolation bug in any deployment behind a reverse
# proxy: every client appears to come from the same upstream IP, so the
# fallback handed user A's POST authentication to whichever user had most
# recently opened a SSE connection from that same upstream (i.e., everyone).
# Symptoms observed in prod 2026-05-11: users seeing each other's agent
# names, identity cards getting overwritten by strangers' `identity_replace`
# tool calls, chat history apparently mixing across accounts.
#
# Fix: drop peer-based fallback entirely. Every tool call must carry the
# api_key on the request itself (via `?key=` query param, `Authorization:
# Bearer`, or `X-API-Key` header). MCP clients that omit the key on POSTs
# are no longer supported — they were never safe to support in shared
# infrastructure. Resolution path is now strictly:
#   1. key present on the current HTTP request → use it directly
#   2. key previously bound to this exact session_id by a prior request
#      that did carry it → use cached
#   3. else: no key, request is unauthenticated, downstream tool call fails

_session_keys: dict[str, str] = {}
_session_keys_lock = threading.Lock()


def _remember(session_id: str | None, key: str, peer: str = ""):
    """Bind `key` to `session_id` if both are present. peer is accepted for
    backward compat with callers but intentionally ignored — see the
    module-level comment above for why peer-based key recovery is unsafe."""
    if not key or not session_id:
        return
    with _session_keys_lock:
        _session_keys[session_id] = key


def _resolve_for_session(session_id: str | None, peer: str = "") -> str | None:
    """Strict session_id → key lookup. Returns None if no exact match.
    peer is accepted (and intentionally ignored) for caller-signature
    compatibility — see the module-level comment for the data-isolation
    incident that this strictness exists to prevent."""
    if not session_id:
        return None
    with _session_keys_lock:
        return _session_keys.get(session_id)


# ---------------------------------------------------------------------------
# ASGI middleware — runs on every HTTP request
# ---------------------------------------------------------------------------


class KeyCaptureMiddleware(BaseHTTPMiddleware):
    """Extracts api_key from incoming requests and binds it to the right
    MCP SSE session_id.

    Three code paths, in order of preference:

    1. Request carries both `session_id` and `key` (POST /messages/?session_id=Y&key=X
       or POST with `Authorization: Bearer X`): bind immediately, done.

    2. Request is an initial SSE GET (`/sse?key=X`) with NO session_id yet
       — the server is about to assign one inside its SSE response. We wrap
       the response body iterator, peek at the first `event: endpoint`
       chunk, parse the assigned session_id out of its `data:` URL, and
       bind it to the captured key before the chunk leaves the server.
       This is the safe replacement for the old peer-IP fallback: the
       binding uses information that's unique per connection (the
       server-assigned session_id), not the transport-layer peer address
       which is shared behind a reverse proxy.

    3. Request has neither — pass through. Tool calls authenticate via
       whichever path resolves; if nothing resolves, the request fails
       closed (401 from enclave/backend) rather than silently using
       another tenant's key.
    """

    # MCP SSE servers send the first event as:
    #   event: endpoint
    #   data: /messages/?session_id=<uuid>
    # We extract the uuid. Accepting hex+dash matches FastMCP's UUID4
    # session ids; the upper bound on length stops a runaway buffer.
    _ENDPOINT_RE = re.compile(
        rb"event:\s*endpoint\s*\r?\n"
        rb"data:[^\r\n]*?session_id=([A-Za-z0-9\-_]{8,128})"
    )

    async def dispatch(self, request, call_next):
        key = self._extract_key(request)
        session_id = (request.query_params.get("session_id") or "").strip() or None

        # Path 1: key + session_id both present on this request → bind now.
        if key and session_id:
            _remember(session_id, key)

        response = await call_next(request)

        # Path 2: initial SSE GET with key but no session_id yet → sniff
        # the assigned session_id from the response stream and bind it.
        # Path checked structurally rather than by URL string so renames
        # of the SSE endpoint don't silently break this.
        if (
            key
            and not session_id
            and request.method == "GET"
            and hasattr(response, "body_iterator")
            and "text/event-stream" in response.headers.get("content-type", "").lower()
        ):
            response.body_iterator = self._sniff_session_id_and_bind(
                response.body_iterator, key
            )

        return response

    @staticmethod
    def _extract_key(request) -> str:
        # query param "key"
        try:
            k = (request.query_params.get("key") or "").strip()
            if k:
                return k
        except Exception:
            pass
        # Authorization: Bearer <key>
        auth = request.headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        # X-API-Key header
        return (request.headers.get("x-api-key") or "").strip()

    @classmethod
    async def _sniff_session_id_and_bind(cls, body_iterator, key: str):
        """Wrap the SSE response stream. While forwarding chunks unchanged,
        peek at the early bytes for the `event: endpoint` line whose data
        carries the server-assigned session_id. Bind that session_id → key
        the first time we see it, then stop buffering. The wrapping is
        transparent to the SSE client — every chunk is yielded immediately,
        not after the binding completes."""
        bound = False
        # Bounded prefix buffer: the endpoint event is the first one MCP
        # SSE servers emit, so a few KB is more than enough. Without a
        # cap an unusual stream could buffer indefinitely.
        sniff_buf = bytearray()
        sniff_cap = 8192

        async for chunk in body_iterator:
            if not bound:
                # Accumulate just enough bytes to scan for the endpoint
                # event. Forward each chunk first; this is for sniffing,
                # not gating.
                try:
                    sniff_buf.extend(chunk if isinstance(chunk, (bytes, bytearray)) else chunk.encode("utf-8"))
                except Exception:
                    bound = True  # non-byte stream — give up sniffing
                if len(sniff_buf) <= sniff_cap:
                    m = cls._ENDPOINT_RE.search(sniff_buf)
                    if m:
                        sid = m.group(1).decode("ascii", errors="ignore")
                        if sid:
                            _remember(sid, key)
                            print(f"[mcp] bound key to SSE-assigned session_id={sid[:8]}…")
                        bound = True
                        sniff_buf = bytearray()  # release
                else:
                    # Cap hit without finding endpoint event — stop trying.
                    # The session this client uses for POSTs will need to
                    # carry the key on its own (Authorization / ?key=).
                    bound = True
                    sniff_buf = bytearray()
            yield chunk


# ---------------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------------

mcp = FastMCP(
    name="Feedling",
    instructions=(
        "Feedling gives your Agent a body on iOS. "
        "Use these tools to push to Dynamic Island, read the user's screen, "
        "chat with the user, manage the identity card, and tend the memory garden. "
        "Start with feedling_bootstrap on first connection."
    ),
)


def _current_api_key(ctx: Context | None = None) -> str:
    """Best-effort lookup of the current caller's API key."""
    # 1. Try the active HTTP request headers/query
    try:
        req = get_http_request()
        k = (req.query_params.get("key") or "").strip()
        if not k:
            auth = req.headers.get("authorization", "")
            if auth.lower().startswith("bearer "):
                k = auth[7:].strip()
        if not k:
            k = (req.headers.get("x-api-key") or "").strip()
        if k:
            return k
        peer = req.client.host if req.client else ""
        session_id = (req.query_params.get("session_id") or "").strip() or None
        cached = _resolve_for_session(session_id, peer=peer)
        if cached:
            return cached
    except Exception:
        pass

    # 2. Try FastMCP Context session
    if ctx is not None and ctx.session_id:
        cached = _resolve_for_session(ctx.session_id)
        if cached:
            return cached

    # 3. Env fallback (self-hosted default)
    return FALLBACK_API_KEY


def _headers(ctx: Context | None = None) -> dict:
    key = _current_api_key(ctx)
    h = {"Content-Type": "application/json"}
    if key:
        h["X-API-Key"] = key
    return h


# Module-level pooled clients — avoid paying a fresh TCP+TLS handshake
# on every tool call. The backend is in-cluster plain HTTP; the enclave
# is reached over its self-signed TLS surface so verify=False.
_FLASK_HTTP = httpx.Client(
    timeout=60,
    limits=httpx.Limits(max_keepalive_connections=8, max_connections=16),
)
_ENCLAVE_HTTP = httpx.Client(
    timeout=60,
    verify=False,
    limits=httpx.Limits(max_keepalive_connections=8, max_connections=16),
)

# Proactive-push safety gate: require a recent vision-capable decrypt before
# posting Live Activity. Keyed by caller api_key so multi-tenant sessions don't mix.
_REQUIRE_VISION_BEFORE_PUSH = os.environ.get("FEEDLING_REQUIRE_VISION_BEFORE_PUSH", "true").lower() == "true"
_VISION_DECRYPT_TTL_SEC = int(os.environ.get("FEEDLING_VISION_DECRYPT_TTL_SEC", "180"))
_recent_decrypt_by_api_key: dict[str, dict] = {}


def _check_vision_gate(api_key: str | None) -> dict | None:
    """Return a block-reason dict if the vision gate is active and not satisfied,
    or None if the caller may proceed with a Live Activity push."""
    if not _REQUIRE_VISION_BEFORE_PUSH:
        return None
    rec = _recent_decrypt_by_api_key.get(api_key) if api_key else None
    if not rec:
        return {
            "status": "blocked",
            "reason": "vision_gate_missing_decrypt",
            "hint": "Call feedling_screen_decrypt_frame(include_image=true) before pushing to Live Activity.",
        }
    age = time.time() - float(rec.get("ts", 0.0) or 0.0)
    if age > _VISION_DECRYPT_TTL_SEC:
        return {
            "status": "blocked",
            "reason": "vision_gate_stale_decrypt",
            "age_sec": round(age, 2),
            "ttl_sec": _VISION_DECRYPT_TTL_SEC,
            "hint": "Frame analysis is stale. Re-run feedling_screen_decrypt_frame(include_image=true).",
        }
    if not rec.get("include_image"):
        return {
            "status": "blocked",
            "reason": "vision_gate_no_image",
            "hint": "decrypt_frame must be called with include_image=true.",
        }
    return None

# (Phase: relationship-anchor) The relationship anchor used to derive
# days_with_user is now owned by the Flask server (per-user
# `relationship_started_at` field, set via /v1/identity/init or
# /v1/identity/relationship_anchor). The old global env-var fallback
# was removed — agents must pass days_with_user at init time.


def _get(path: str, params: dict | None = None, ctx: Context | None = None) -> dict:
    r = _FLASK_HTTP.get(f"{FLASK_BASE}{path}", params=params, headers=_headers(ctx))
    r.raise_for_status()
    return r.json()


def _get_decrypted(path: str, params: dict | None = None, ctx: Context | None = None) -> dict:
    """Read a content endpoint through the enclave's decrypt proxy when
    one is configured, otherwise fall back to Flask.

    The enclave hosts mirrors of /v1/chat/history, /v1/memory/list, and
    /v1/identity/get that unseal K_enclave and AEAD-decrypt the body
    before responding. Agents — which don't hold user_sk — need this
    path to read v1 envelopes at all.
    """
    if not ENCLAVE_BASE:
        return _get(path, params=params, ctx=ctx)
    r = _ENCLAVE_HTTP.get(f"{ENCLAVE_BASE}{path}", params=params, headers=_headers(ctx))
    r.raise_for_status()
    return r.json()


def _post(path: str, body: dict, ctx: Context | None = None) -> dict:
    r = _FLASK_HTTP.post(f"{FLASK_BASE}{path}", json=body, headers=_headers(ctx))
    r.raise_for_status()
    return r.json()


def _delete(path: str, params: dict | None = None, ctx: Context | None = None) -> dict:
    r = _FLASK_HTTP.delete(f"{FLASK_BASE}{path}", params=params, headers=_headers(ctx))
    r.raise_for_status()
    return r.json()


def _whoami_pubkeys(ctx: Context | None = None) -> tuple[str, bytes | None, bytes | None]:
    """Resolve (owner_user_id, user_pk_bytes, enclave_pk_bytes) for the
    current caller by hitting /v1/users/whoami on the backend.

    Returns bytes=None for either pubkey if the backend can't supply it
    (malformed whoami response, or no reachable enclave). In that case
    wrap-required tools fail loud rather than leak plaintext.
    """
    try:
        info = _get("/v1/users/whoami", ctx=ctx)
    except Exception as e:
        print(f"[wrap] whoami failed: {e}")
        return ("", None, None)

    user_id = info.get("user_id", "") or ""
    user_pk_b64 = (info.get("public_key") or "").strip()
    enc_pk_hex = (info.get("enclave_content_public_key_hex") or "").strip()

    try:
        user_pk_bytes = base64.b64decode(user_pk_b64) if user_pk_b64 else None
        if user_pk_bytes is not None and len(user_pk_bytes) != 32:
            user_pk_bytes = None
    except Exception:
        user_pk_bytes = None

    try:
        enc_pk_bytes = bytes.fromhex(enc_pk_hex) if enc_pk_hex else None
        if enc_pk_bytes is not None and len(enc_pk_bytes) != 32:
            enc_pk_bytes = None
    except Exception:
        enc_pk_bytes = None

    return (user_id, user_pk_bytes, enc_pk_bytes)


# ---------------------------------------------------------------------------
# Push tools
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling_push_dynamic_island",
    description=(
        "Push to the user's iPhone Dynamic Island / Live Activity. "
        "title appears as the heading (e.g. your Agent name). "
        "body is the main message. "
        "subtitle is optional one-line context. "
        "data is a free-form key-value bag. "
        "The platform enforces a cooldown — check feedling_screen_analyze rate_limit_ok before pushing."
    ),
)
def push_dynamic_island(
    title: str,
    body: str,
    subtitle: str = "",
    data: dict | None = None,
    event: str = "update",
    ctx: Context = None,
) -> dict:
    return _post("/v1/push/dynamic-island", {
        "title": title,
        "body": body,
        "subtitle": subtitle or None,
        "data": data or {},
        "event": event,
    }, ctx=ctx)


@mcp.tool(
    name="feedling_push_live_activity",
    description=(
        "Update the Live Activity on the user's lock screen and Dynamic Island. "
        "By default, the same message is also synced into chat history so lock-screen "
        "and chat stay consistent."
    ),
)
def push_live_activity(
    title: str,
    body: str,
    subtitle: str = "",
    data: dict | None = None,
    event: str = "update",
    sync_chat: bool = True,
    ctx: Context = None,
) -> dict:
    payload_data = dict(data or {})

    api_key = _current_api_key(ctx)
    blocked = _check_vision_gate(api_key)
    if blocked:
        return blocked

    rec = _recent_decrypt_by_api_key.get(api_key) if api_key else None
    if rec:
        payload_data.setdefault("analysis_source", "vision")
        payload_data.setdefault("frame_id", rec.get("frame_id", ""))

    push_result = _post("/v1/push/live-activity", {
        "title": title,
        "body": body,
        "subtitle": subtitle or None,
        "data": payload_data,
        "event": event,
    }, ctx=ctx)

    if sync_chat and (body or "").strip():
        user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
        if user_id and user_pk is not None and enclave_pk is not None:
            envelope = build_envelope(
                plaintext=body.encode("utf-8"),
                owner_user_id=user_id,
                user_pk_bytes=user_pk,
                enclave_pk_bytes=enclave_pk,
                visibility="shared",
            )
            chat_result = _post("/v1/chat/response", {"envelope": envelope}, ctx=ctx)
            push_result["chat_sync"] = chat_result.get("status", "ok")
            push_result["chat_id"] = chat_result.get("id")
        else:
            push_result["chat_sync"] = "skipped_no_pubkeys"

    return push_result


# ---------------------------------------------------------------------------
# Screen tools
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling_screen_latest_frame",
    description=(
        "Metadata ONLY for the most recent screen frame (timestamp, frame id, "
        "filename, envelope url). Every frame is a v1 envelope, so app/ocr_text "
        "come back empty and there is no plaintext image here. To actually SEE "
        "the screen — pixels + real OCR text — call feedling_screen_decrypt_frame "
        "(it defaults to the latest frame)."
    ),
)
def screen_latest_frame(ctx: Context = None) -> dict:
    return _get("/v1/screen/frames/latest", ctx=ctx)


@mcp.tool(
    name="feedling_screen_frames_list",
    description=(
        "List recent screen frame metadata (timestamp, frame id, filename) from "
        "the user's iOS device. Frames are v1 envelopes so app and ocr_text in "
        "this listing are always empty — use feedling_screen_decrypt_frame with a "
        "specific frame_id to get real OCR + app + pixels for any frame. limit "
        "defaults to 20, max 100."
    ),
)
def screen_frames_list(limit: int = 20, ctx: Context = None) -> dict:
    return _get("/v1/screen/frames", {"limit": max(1, min(limit, 100))}, ctx=ctx)


@mcp.tool(
    name="feedling_screen_analyze",
    description=(
        "Get a structured analysis of the user's current screen activity: "
        "foreground app, OCR summary, and whether the push cooldown has elapsed."
    ),
)
def screen_analyze(ctx: Context = None) -> dict:
    return _get("/v1/screen/analyze", ctx=ctx)


@mcp.tool(
    name="feedling_screen_summary",
    description=(
        "Get today's screen-time rollup for the user (iOS + Mac): total minutes, "
        "top app, top category, pickups. Aggregated server-side from the last 24h "
        "of frames. Use for daily-report-style questions."
    ),
)
def screen_summary(ctx: Context = None) -> dict:
    return _get("/v1/screen/summary", ctx=ctx)


@mcp.tool(
    name="feedling_screen_decrypt_frame",
    description=(
        "Decrypt a screen-frame envelope and return the actual pixels + OCR "
        "text so the Agent can SEE the frame. Runs inside the enclave — the "
        "plaintext never leaves the TDX boundary except on the wire back to "
        "the authenticated caller. If frame_id is omitted, the most recent "
        "frame is used. Returns a list with the JPEG image (so vision "
        "activates) and a text block containing ocr_text + app + ts metadata."
    ),
    output_schema=None,
)
def screen_decrypt_frame(
    frame_id: str = "",
    include_image: bool = True,
    ctx: Context = None,
):
    """Resolve a frame id (or pick the latest), ask the enclave to
    decrypt, and return an MCP content list the agent can consume:

        [ Image(jpeg_bytes, format="jpeg"),   # vision block
          "{json metadata with ocr_text}"     # text block ]

    If include_image is False, returns a dict with ocr_text + metadata
    only — useful when the caller just wants text and wants to avoid the
    bandwidth cost of shipping JPEG base64.
    """
    if not ENCLAVE_BASE:
        return {"error": "enclave not configured — FEEDLING_ENCLAVE_URL missing"}

    # Resolve frame_id lazily — empty means "latest".
    fid = (frame_id or "").strip()
    if not fid:
        try:
            listing = _get("/v1/screen/frames", {"limit": 1}, ctx=ctx)
        except httpx.HTTPError as e:
            return {"error": f"frames_list_failed: {e}"}
        frames = listing.get("frames") or []
        if not frames:
            return {"error": "no frames on record yet"}
        fid = frames[0].get("id") or ""
        if not fid:
            return {"error": "latest frame has no id"}

    try:
        r = _ENCLAVE_HTTP.get(
            f"{ENCLAVE_BASE}/v1/screen/frames/{fid}/decrypt",
            headers=_headers(ctx),
            params={"include_image": "true" if include_image else "false"},
        )
        r.raise_for_status()
        payload = r.json()
    except httpx.HTTPError as e:
        return {"error": f"enclave_decrypt_failed: {e}", "frame_id": fid}

    if payload.get("error"):
        return payload

    metadata = {k: v for k, v in payload.items() if k not in ("image_b64",)}
    if not include_image:
        # Return a plain dict so callers don't need to special-case list payloads.
        return metadata

    img_b64 = payload.get("image_b64") or ""
    if not img_b64:
        return {"warning": "decrypt ok but no image_b64 in plaintext", **metadata}

    try:
        jpeg_bytes = base64.b64decode(img_b64)
    except Exception as e:
        return {"error": f"image_b64_decode: {e}", **metadata}

    api_key = _current_api_key(ctx)
    if api_key:
        _recent_decrypt_by_api_key[api_key] = {
            "frame_id": fid,
            "ts": time.time(),
            "include_image": bool(include_image),
            "ocr_chars": len(metadata.get("ocr_text") or ""),
        }

    print(f"[mcp] decrypt_frame id={fid} bytes={len(jpeg_bytes)} ocr_chars={len(metadata.get('ocr_text') or '')}")
    # FastMCP serializes list returns as a multi-block MCP tool result:
    # the Image becomes an ImageContent the agent's vision reads, and the
    # dict becomes structuredContent + a JSON-serialized text block.
    return [Image(data=jpeg_bytes, format="jpeg"), metadata]


# ---------------------------------------------------------------------------
# Chat tools
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling_chat_post_message",
    description=(
        "Post a message from the Agent into the Feedling iOS chat window. "
        "Optionally mirror the same text to Live Activity in the same backend call "
        "to reduce chat/live divergence."
    ),
)
def chat_post_message(
    content: str,
    push_live_activity: bool = False,
    push_body: str = "",
    title: str = "",
    subtitle: str = "",
    data: dict | None = None,
    ctx: Context = None,
) -> dict:
    """Agent posts a reply as a v1 envelope.

    Reliability note:
    - When `push_live_activity=True`, this sends chat write + live activity trigger
      through ONE `/v1/chat/response` request (same backend code path), which avoids
      split-brain failures where push succeeds but chat writeback is missed.
    """
    if push_live_activity:
        blocked = _check_vision_gate(_current_api_key(ctx))
        if blocked:
            return blocked

    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if not (user_id and user_pk is not None and enclave_pk is not None):
        return {"error": "cannot post chat — pubkeys unavailable"}

    envelope = build_envelope(
        plaintext=content.encode("utf-8"),
        owner_user_id=user_id,
        user_pk_bytes=user_pk,
        enclave_pk_bytes=enclave_pk,
        visibility="shared",
    )

    payload: dict = {"envelope": envelope}
    # Plaintext for the APNs alert push. MCP has plaintext at this point
    # (we just sealed it), so we hand it directly to Flask — the server
    # never decrypts the envelope itself. Apple's APNs gateway sees this
    # string, same privacy posture as Live Activity push.
    payload["alert_body"] = content
    if push_live_activity:
        payload["push_live_activity"] = True
        payload["push_body"] = push_body or content
        payload["title"] = title or ""
        if subtitle:
            payload["subtitle"] = subtitle
        if data:
            payload["data"] = data

    print(
        f"[mcp] chat.post_message v1 envelope id={envelope['id']} "
        f"push_live_activity={bool(push_live_activity)}"
    )
    return _post("/v1/chat/response", payload, ctx=ctx)


@mcp.tool(
    name="feedling_chat_post_image",
    description=(
        "Post an IMAGE message from the Agent into the user's chat window. "
        "Use this when sharing what you see is genuinely valuable — generated "
        "screenshots, vision-derived images, found images you want the user "
        "to look at. Don't post decorative or redundant images. "
        "Image and text are separate messages: this tool only takes the image. "
        "If you want to caption the image, send `feedling_chat_post_message` "
        "as a separate message. "
        "Privacy hard rule: NEVER include content from the user's screen "
        "(decrypt_frame outputs) — agent seeing the screen ≠ user wanting "
        "the screen archived in their chat history."
    ),
)
def chat_post_image(
    image_b64: str,
    ctx: Context = None,
) -> dict:
    """Agent posts an image (base64-encoded JPEG/PNG, ≤ 1 MB after decode)
    as a v1 chat envelope with content_type=image."""
    if not image_b64 or not isinstance(image_b64, str):
        return {"error": "image_b64 required (non-empty base64 string)"}
    try:
        # Strip optional data-URL prefix if the caller included one.
        b64 = image_b64.split(",", 1)[1] if image_b64.startswith("data:") else image_b64
        image_bytes = base64.b64decode(b64, validate=True)
    except Exception as e:
        return {"error": f"image_b64 base64 decode failed: {e}"}
    if len(image_bytes) == 0:
        return {"error": "image_b64 decoded to 0 bytes"}
    if len(image_bytes) > 1_048_576:
        return {"error": f"image too large: {len(image_bytes)} bytes (max 1 MB)"}

    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if not (user_id and user_pk is not None and enclave_pk is not None):
        return {"error": "cannot post chat — pubkeys unavailable"}

    envelope = build_envelope(
        plaintext=image_bytes,
        owner_user_id=user_id,
        user_pk_bytes=user_pk,
        enclave_pk_bytes=enclave_pk,
        visibility="shared",
    )
    # Generic alert body for image messages — agent didn't supply a caption
    # (per spec, image and text are separate messages). User taps in to see.
    payload: dict = {
        "envelope": envelope,
        "content_type": "image",
        "alert_body": "[image]",
    }
    print(
        f"[mcp] chat.post_image v1 envelope id={envelope['id']} bytes={len(image_bytes)}"
    )
    return _post("/v1/chat/response", payload, ctx=ctx)


@mcp.tool(
    name="feedling_chat_get_history",
    description=(
        "Retrieve recent chat history between the user and the Agent. The "
        "response includes a `context_memories` field — up to 8 plaintext "
        "memory cards the server selected as relevant to this conversation "
        "moment (turning points + recent + keyword overlap with the latest "
        "user message). Read both `messages` and `context_memories` before "
        "composing your reply. Weave relevant memories naturally — pretend "
        "you 'just remembered,' not 'looked up.' Don't reference cards by id, "
        "don't say 'according to memory X.' If none feel relevant to the "
        "current exchange, ignore them — irrelevant references hurt more "
        "than they help. "
        "Image messages (content_type='image') return as TWO things: "
        "(1) a marker `<vision_block:N>` in the message's `image_b64` field, "
        "and (2) the actual JPEG as an ImageContent block at index N in this "
        "tool's response. Vision-capable agents see the image automatically. "
        "Acknowledge what you see; do NOT echo the marker text to the user."
    ),
    output_schema=None,
)
def chat_get_history(limit: int = 50, ctx: Context = None):
    """Returns chat history. For text-only history, returns a single dict.
    For history containing image messages, returns a list:
    `[history_dict, Image(jpeg1), Image(jpeg2), ...]` — the dict has its
    image_b64 fields replaced with `<vision_block:N>` markers that index
    into the trailing Image blocks. FastMCP serializes this multi-block
    return so the agent's vision actually activates on each image, rather
    than receiving the base64 as opaque text (which is what happened
    before this change — image messages silently broke agent replies).
    """
    raw = _get_decrypted("/v1/chat/history", {"limit": min(limit, 200)}, ctx=ctx)
    if not isinstance(raw, dict) or "messages" not in raw:
        return raw

    image_blocks: list = []
    for m in raw.get("messages", []):
        if not isinstance(m, dict):
            continue
        if m.get("content_type") != "image":
            continue
        b64 = m.get("image_b64") or ""
        if not b64:
            continue
        try:
            jpeg_bytes = base64.b64decode(b64)
        except Exception as e:
            m["image_b64"] = f"<decode_failed: {e}>"
            continue
        marker_idx = len(image_blocks)
        image_blocks.append(Image(data=jpeg_bytes, format="jpeg"))
        # Replace the (large) base64 with a small marker so the JSON text
        # block stays compact; the actual image data is now in the
        # corresponding ImageContent block at position marker_idx + 1.
        m["image_b64"] = f"<vision_block:{marker_idx}>"

    if image_blocks:
        print(f"[mcp] chat_get_history: surfacing {len(image_blocks)} image(s) as ImageContent blocks")
        return [raw, *image_blocks]
    return raw


# ---------------------------------------------------------------------------
# Identity card
# ---------------------------------------------------------------------------


def _build_and_post_identity(
    endpoint: str,
    op_label: str,
    agent_name: str,
    self_introduction: str,
    dimensions: list[dict],
    days_with_user: int | None,
    category: str,
    signature: list[str] | None,
    ctx: Context | None,
) -> dict:
    """Shared encrypt-and-POST path used by both identity_init and identity_replace.

    Wraps the identity card into a v1 envelope. MCP runs inside the enclave so
    wrapping prerequisites are always available; if they're not, fail loud
    rather than regress to plaintext.

    days_with_user is NOT placed inside the envelope. It travels alongside the
    envelope and Flask converts it to a server-side `relationship_started_at`
    anchor — that anchor is the single source of truth for the live count.
    """
    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if not (user_id and user_pk is not None and enclave_pk is not None):
        return {"error": f"cannot {op_label} identity — pubkeys unavailable"}
    body: dict = {
        "agent_name": agent_name,
        "self_introduction": self_introduction,
        "dimensions": dimensions,
    }
    if category:
        body["category"] = category
    if signature:
        body["signature"] = signature
    inner = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    envelope = build_envelope(
        plaintext=inner,
        owner_user_id=user_id,
        user_pk_bytes=user_pk,
        enclave_pk_bytes=enclave_pk,
        visibility="shared",
    )
    post_payload: dict = {"envelope": envelope}
    if days_with_user is not None:
        post_payload["days_with_user"] = int(max(0, days_with_user))
    print(f"[mcp] identity.{op_label} v1 envelope id={envelope['id']} days_with_user={days_with_user}")
    return _post(endpoint, post_payload, ctx=ctx)


@mcp.tool(
    name="feedling_identity_init",
    description=(
        "Initialize the Agent's identity card. Call this AFTER you've completed the "
        "memory garden's 4-pass extraction — every identity field is DERIVED from "
        "memories, not guessed. Requires exactly 7 dimensions; each has name (string), "
        "value (0-100), description (string). For each dimension you must be able to "
        "name ≥3 specific memory cards as receipts — if you can't, drop that dimension "
        "and pick one you can defend. "
        "days_with_user (REQUIRED): computed as floor((today − earliest_memory.occurred_at) / 1 day). "
        "Do not guess this value — derive it from the memories you wrote. "
        "agent_name: NEVER use a runtime label (Hermes / Claude / GPT / etc.). "
        "Use the name the user has called you in prior chats; if none, propose one and "
        "let the user accept. "
        "category: short descriptor e.g. 'Quiet · Observant'. "
        "signature: defer until after the user answers your push-preference question."
    ),
)
def identity_init(
    agent_name: str,
    self_introduction: str,
    dimensions: list[dict],
    days_with_user: int,
    category: str = "",
    signature: list[str] = None,
    ctx: Context = None,
) -> dict:
    """First-time identity write. days_with_user is mandatory — it sets the
    server-side relationship anchor. Returns 409 from the backend if the card
    already exists — use feedling_identity_replace to overwrite."""
    return _build_and_post_identity(
        "/v1/identity/init", "init",
        agent_name, self_introduction, dimensions,
        days_with_user, category, signature, ctx,
    )


@mcp.tool(
    name="feedling_identity_replace",
    description=(
        "Fully rewrite the Agent's identity card in place. Unlike "
        "feedling_identity_init (which 409s once initialized), this overwrites "
        "the existing card. Use when the user wants to change agent_name, "
        "rewrite self_introduction, or restructure the dimension list. "
        "For tweaking a single dimension's value, prefer feedling_identity_nudge. "
        "days_with_user is OPTIONAL here — leave it unset to preserve the existing "
        "relationship anchor. Only pass it if the user explicitly asks to recalibrate "
        "the relationship age (in which case prefer feedling_identity_set_relationship_days, "
        "which is lighter)."
    ),
)
def identity_replace(
    agent_name: str,
    self_introduction: str,
    dimensions: list[dict],
    days_with_user: int | None = None,
    category: str = "",
    signature: list[str] = None,
    ctx: Context = None,
) -> dict:
    """In-place identity overwrite. days_with_user is optional — omit to keep
    the current relationship anchor unchanged."""
    return _build_and_post_identity(
        "/v1/identity/replace", "replace",
        agent_name, self_introduction, dimensions,
        days_with_user, category, signature, ctx,
    )


@mcp.tool(
    name="feedling_identity_set_relationship_days",
    description=(
        "Recalibrate the relationship-age anchor without rewriting the identity card. "
        "Use this in the bootstrap calibration step: after init, you tell the user "
        "your estimate ('we've known each other ~90 days, right?') and if they "
        "correct you ('actually it's been 6 months'), call this tool with the "
        "corrected day count. The server converts it to a fixed timestamp; the "
        "displayed count auto-increments every day after. After calibration, you "
        "should never write days_with_user again."
    ),
)
def identity_set_relationship_days(days_with_user: int, ctx: Context = None) -> dict:
    """Lightweight anchor update. No envelope re-encryption."""
    if not isinstance(days_with_user, int) or days_with_user < 0:
        return {"error": "days_with_user must be a non-negative int"}
    print(f"[mcp] identity.set_relationship_days days={days_with_user}")
    return _post("/v1/identity/relationship_anchor", {"days_with_user": days_with_user}, ctx=ctx)


@mcp.tool(
    name="feedling_identity_get",
    description="Retrieve the current identity card.",
)
def identity_get(ctx: Context = None) -> dict:
    return _get_decrypted("/v1/identity/get", ctx=ctx)


@mcp.tool(
    name="feedling_identity_nudge",
    description=(
        "Micro-adjust a single dimension on the identity card. "
        "delta can be positive or negative (e.g. +5 or -3). "
        "Include a reason so the history is meaningful."
    ),
)
def identity_nudge(dimension_name: str, delta: int, reason: str = "", ctx: Context = None) -> dict:
    """MCP orchestrates the decrypt → mutate → rewrap → replace dance for
    the (always-v1) identity card.

    Flow:
      1. GET /v1/identity/get on the ENCLAVE (returns decrypted card).
      2. Find the matching dimension, clamp `value += delta` to [0, 100],
         record `last_nudge_reason`.
      3. Re-build the card envelope with `build_envelope`.
      4. POST /v1/identity/replace on the backend.

    Plaintext is confined to the MCP process inside the enclave-compose
    boundary. Server-side storage stays ciphertext throughout.
    """
    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if not (user_id and user_pk is not None and enclave_pk is not None):
        return {"error": "cannot nudge v1 card — pubkeys unavailable"}

    # Fetch the decrypted card through the enclave proxy.
    decoded = _get_decrypted("/v1/identity/get", ctx=ctx)
    ident = decoded.get("identity") or {}
    dims = list(ident.get("dimensions") or [])
    if not dims:
        return {"error": "identity not initialized or has no dimensions"}

    matched = next((d for d in dims if d.get("name") == dimension_name), None)
    if matched is None:
        return {"error": f"dimension '{dimension_name}' not found"}
    new_val = max(0, min(100, int(matched.get("value", 0)) + int(delta)))
    matched["value"] = new_val
    if reason:
        matched["last_nudge_reason"] = reason

    body: dict = {
        "agent_name": ident.get("agent_name", ""),
        "self_introduction": ident.get("self_introduction", ""),
        "dimensions": dims,
    }
    # days_with_user is NOT in the envelope anymore — server owns the anchor.
    if ident.get("category"):
        body["category"] = ident["category"]
    if ident.get("signature"):
        body["signature"] = ident["signature"]
    inner = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    envelope = build_envelope(
        plaintext=inner,
        owner_user_id=user_id,
        user_pk_bytes=user_pk,
        enclave_pk_bytes=enclave_pk,
        visibility="shared",
    )
    print(f"[mcp] identity.nudge v1 rewrap dim={dimension_name} {delta:+d} → {new_val}")
    return _post("/v1/identity/replace", {"envelope": envelope}, ctx=ctx)


# ---------------------------------------------------------------------------
# Memory garden
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling_memory_add_moment",
    description=(
        "Add a moment to the memory garden. "
        "occurred_at is ISO 8601 (e.g. 2025-11-03T14:00:00). "
        "source should be 'bootstrap', 'live_conversation', or 'user_initiated'."
    ),
)
def memory_add_moment(
    title: str,
    occurred_at: str,
    description: str = "",
    type: str = "",
    source: str = "live_conversation",
    ctx: Context = None,
) -> dict:
    """Wrap the memory moment into a v1 envelope before POSTing. MCP runs
    inside the enclave-compose boundary so wrapping prerequisites are
    always available; if they're not, fail loud.
    """
    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if not (user_id and user_pk is not None and enclave_pk is not None):
        return {"error": "cannot add memory — pubkeys unavailable"}
    inner = json.dumps({
        "title": title,
        "description": description,
        "type": type,
    }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    envelope = build_envelope(
        plaintext=inner,
        owner_user_id=user_id,
        user_pk_bytes=user_pk,
        enclave_pk_bytes=enclave_pk,
        visibility="shared",
    )
    # occurred_at + source are plaintext metadata the server uses
    # for sorting/indexing. They ride alongside the ciphertext inside
    # the envelope dict per the schema in /v1/memory/add.
    envelope["occurred_at"] = occurred_at
    envelope["source"] = source
    print(f"[mcp] memory.add v1 envelope id={envelope['id']} body_ct_len={len(envelope['body_ct'])}")
    return _post("/v1/memory/add", {"envelope": envelope}, ctx=ctx)


@mcp.tool(
    name="feedling_memory_list",
    description="List moments in the memory garden, ordered by occurred_at descending.",
)
def memory_list(limit: int = 20, ctx: Context = None) -> dict:
    return _get_decrypted("/v1/memory/list", {"limit": limit}, ctx=ctx)


@mcp.tool(
    name="feedling_memory_get",
    description="Get a single moment by its id.",
)
def memory_get(id: str, ctx: Context = None) -> dict:
    return _get("/v1/memory/get", {"id": id}, ctx=ctx)


@mcp.tool(
    name="feedling_memory_delete",
    description="Delete a moment from the memory garden by its id.",
)
def memory_delete(id: str, ctx: Context = None) -> dict:
    return _delete("/v1/memory/delete", {"id": id}, ctx=ctx)


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling_bootstrap",
    description=(
        "Call this on first connection to Feedling. "
        "Returns instructions for the Agent to complete the aha moment: "
        "fill the identity card, plant memory garden moments, and say hello. "
        "Returns 'already_bootstrapped' on subsequent calls."
    ),
)
def bootstrap(ctx: Context = None) -> dict:
    return _post("/v1/bootstrap", {}, ctx=ctx)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


# Fingerprint of the currently-active MCP TLS cert public key (set at boot).
# acme_dns01: sha256(SubjectPublicKeyInfo DER) — stable across LE renewals.
# dstack-KMS fallback: sha256(cert.DER) of the self-signed cert.
_mcp_cert_pubkey_fingerprint_hex: str = ""


def _acquire_tls_cert() -> tuple[str | None, str | None]:
    """Acquire TLS cert for MCP.

    Priority:
      1. FEEDLING_ACME_DOMAIN set → ACME-DNS-01 via Cloudflare; cert from
         Let's Encrypt for the given domain. Cert key derived from dstack-KMS
         at 'feedling-mcp-tls-v1' (stable; fingerprint can be pre-computed
         by enclave_app for the attestation bundle).
      2. FEEDLING_MCP_TLS=true, no ACME → dstack-KMS self-signed cert (Phase C.1
         fallback; same cert as attestation port, fingerprint in bundle).
      3. Neither → HTTP only (local dev).
    """
    global _mcp_cert_pubkey_fingerprint_hex

    if os.environ.get("DSTACK_SIMULATOR_ENDPOINT", "") == "":
        os.environ.pop("DSTACK_SIMULATOR_ENDPOINT", None)

    acme_domain = os.environ.get("FEEDLING_ACME_DOMAIN", "").strip()

    if acme_domain:
        try:
            from dstack_sdk import DstackClient
            from dstack_tls import derive_key_only, MCP_TLS_KEY_PATH, ACME_ACCOUNT_KEY_PATH
            import acme_dns01

            dstack = DstackClient()
            account_key = derive_key_only(dstack, ACME_ACCOUNT_KEY_PATH)
            cert_key = derive_key_only(dstack, MCP_TLS_KEY_PATH)

            result = acme_dns01.get_or_renew(
                domain=acme_domain,
                email=os.environ.get("FEEDLING_ACME_EMAIL", "sxysun9@gmail.com"),
                cf_token=os.environ["FEEDLING_CF_API_TOKEN"],
                cf_zone_id=os.environ["FEEDLING_CF_ZONE_ID"],
                account_key=account_key,
                cert_key=cert_key,
                cache_dir=os.environ.get("FEEDLING_TLS_CACHE_DIR", "/tls"),
                staging=os.environ.get("FEEDLING_ACME_STAGING", "false").lower() == "true",
            )

            _mcp_cert_pubkey_fingerprint_hex = result["pubkey_fingerprint_hex"]
            print(
                f"[mcp] ACME cert acquired for {acme_domain}: "
                f"pubkey_fp={_mcp_cert_pubkey_fingerprint_hex[:32]}…",
                flush=True,
            )

            acme_dns01.start_renewal_watchdog(
                domain=acme_domain,
                email=os.environ.get("FEEDLING_ACME_EMAIL", "sxysun9@gmail.com"),
                cf_token=os.environ["FEEDLING_CF_API_TOKEN"],
                cf_zone_id=os.environ["FEEDLING_CF_ZONE_ID"],
                account_key=account_key,
                cert_key=cert_key,
                cache_dir=os.environ.get("FEEDLING_TLS_CACHE_DIR", "/tls"),
                staging=os.environ.get("FEEDLING_ACME_STAGING", "false").lower() == "true",
            )

            cert_f = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
            key_f = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
            cert_f.write(result["cert_pem"]); cert_f.flush(); cert_f.close()
            key_f.write(result["key_pem"]); key_f.flush(); key_f.close()
            return (cert_f.name, key_f.name)

        except Exception as e:
            print(f"[mcp] ACME failed: {e} — falling back to dstack-KMS cert", flush=True)

    if os.environ.get("FEEDLING_MCP_TLS", "false").lower() != "true":
        return (None, None)

    from dstack_sdk import DstackClient
    from dstack_tls import derive_tls_cert_and_key
    import hashlib as _hl

    dstack = DstackClient()
    tls = derive_tls_cert_and_key(dstack)
    _mcp_cert_pubkey_fingerprint_hex = _hl.sha256(tls["cert_der"]).hexdigest()

    cert_f = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
    key_f = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
    cert_f.write(tls["cert_pem"]); cert_f.flush(); cert_f.close()
    key_f.write(tls["key_pem"]); key_f.flush(); key_f.close()
    return (cert_f.name, key_f.name)


if __name__ == "__main__":
    port = int(os.environ.get("FEEDLING_MCP_PORT", 5002))
    transport = os.environ.get("FEEDLING_MCP_TRANSPORT", "sse").lower()
    cert_path, key_path = _acquire_tls_cert()
    tls_on = cert_path is not None
    scheme = "https" if tls_on else "http"
    print(f"Feedling MCP server: transport={transport} port={port} scheme={scheme} "
          f"flask={FLASK_BASE}")

    if transport == "sse":
        # Build a Starlette app so we can attach the key-capture middleware,
        # then run it with uvicorn. GZipMiddleware compresses tool-call
        # responses above 500 B — decrypt_frame with include_image=true
        # ships ~470 KB of base64 JPEG inside JSON, and CVM egress is
        # ~30-50 KB/s without compression; gzip cuts the wire payload
        # by ~35-45% and turns a 6-10s call into ~2-3s.
        import uvicorn
        from starlette.middleware import Middleware as StarletteMW
        from starlette.middleware.gzip import GZipMiddleware
        app = mcp.http_app(
            transport="sse",
            middleware=[
                StarletteMW(GZipMiddleware, minimum_size=500),
                StarletteMW(KeyCaptureMiddleware),
            ],
        )
        if tls_on:
            uvicorn.run(app, host="0.0.0.0", port=port,
                        ssl_certfile=cert_path, ssl_keyfile=key_path,
                        log_level="info")
        else:
            uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
    else:
        mcp.run(transport=transport, host="0.0.0.0", port=port)
