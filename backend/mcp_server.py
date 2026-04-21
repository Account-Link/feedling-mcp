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
#   - Some include it only on the initial SSE GET.
#   - Some support `Authorization: Bearer <key>` headers end-to-end.
# Cover all three: an ASGI middleware observes every HTTP request, extracts a
# key if present, and caches it under whichever session_id we can infer.

_session_keys: dict[str, str] = {}
_session_keys_lock = threading.Lock()
# When we see `?key=` on the initial SSE GET, we don't yet know the session_id
# assigned by the server. Stash it keyed by client address + path until the
# next POST with session_id binds them together. Kept tiny; oldest entry wins.
_pending_keys: list[tuple[float, str, str]] = []  # (ts, peer, key)
_pending_keys_max = 256


def _remember(session_id: str | None, key: str, peer: str = ""):
    if not key:
        return
    import time
    if session_id:
        with _session_keys_lock:
            _session_keys[session_id] = key
    else:
        with _session_keys_lock:
            _pending_keys.append((time.time(), peer, key))
            if len(_pending_keys) > _pending_keys_max:
                _pending_keys[:] = _pending_keys[-_pending_keys_max:]


def _resolve_for_session(session_id: str | None, peer: str = "") -> str | None:
    if session_id:
        with _session_keys_lock:
            k = _session_keys.get(session_id)
            if k:
                return k
    # fall back to pending keys from same peer
    with _session_keys_lock:
        for ts, p, k in reversed(_pending_keys):
            if peer and p == peer:
                if session_id:
                    _session_keys[session_id] = k
                return k
    return None


# ---------------------------------------------------------------------------
# ASGI middleware — runs on every HTTP request
# ---------------------------------------------------------------------------


class KeyCaptureMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        key = ""
        # query param "key"
        try:
            key = (request.query_params.get("key") or "").strip()
        except Exception:
            key = ""
        # Authorization: Bearer <key>
        if not key:
            auth = request.headers.get("authorization", "")
            if auth.lower().startswith("bearer "):
                key = auth[7:].strip()
        # X-API-Key header
        if not key:
            key = (request.headers.get("x-api-key") or "").strip()

        session_id = (request.query_params.get("session_id") or "").strip() or None
        peer = request.client.host if request.client else ""
        if key:
            _remember(session_id, key, peer=peer)

        response = await call_next(request)
        return response


# ---------------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------------

mcp = FastMCP(
    name="Feedling",
    instructions=(
        "Feedling gives your Agent a body on iOS. "
        "Use these tools to push to Dynamic Island, read the user's screen, "
        "chat with the user, manage the identity card, and tend the memory garden. "
        "Start with feedling.bootstrap on first connection."
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


def _get(path: str, params: dict | None = None, ctx: Context | None = None) -> dict:
    with httpx.Client(timeout=60) as client:
        r = client.get(f"{FLASK_BASE}{path}", params=params, headers=_headers(ctx))
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
    with httpx.Client(timeout=60, verify=False) as client:
        r = client.get(f"{ENCLAVE_BASE}{path}", params=params, headers=_headers(ctx))
        r.raise_for_status()
        return r.json()


def _post(path: str, body: dict, ctx: Context | None = None) -> dict:
    with httpx.Client(timeout=60) as client:
        r = client.post(f"{FLASK_BASE}{path}", json=body, headers=_headers(ctx))
        r.raise_for_status()
        return r.json()


def _delete(path: str, params: dict | None = None, ctx: Context | None = None) -> dict:
    with httpx.Client(timeout=60) as client:
        r = client.delete(f"{FLASK_BASE}{path}", params=params, headers=_headers(ctx))
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
    name="feedling.push.dynamic_island",
    description=(
        "Push to the user's iPhone Dynamic Island / Live Activity. "
        "title appears as the heading (e.g. your Agent name). "
        "body is the main message. "
        "subtitle is optional one-line context. "
        "data is a free-form key-value bag. "
        "The platform enforces a cooldown — check feedling.screen.analyze rate_limit_ok before pushing."
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
    name="feedling.push.live_activity",
    description="Update the Live Activity on the user's lock screen and Dynamic Island.",
)
def push_live_activity(
    title: str,
    body: str,
    subtitle: str = "",
    data: dict | None = None,
    event: str = "update",
    ctx: Context = None,
) -> dict:
    return _post("/v1/push/live-activity", {
        "title": title,
        "body": body,
        "subtitle": subtitle or None,
        "data": data or {},
        "event": event,
    }, ctx=ctx)


# ---------------------------------------------------------------------------
# Screen tools
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling.screen.latest_frame",
    description=(
        "Get the most recent screen frame captured from the user's iOS device, "
        "including OCR text, the foreground app, and a timestamp."
    ),
)
def screen_latest_frame(ctx: Context = None) -> dict:
    return _get("/v1/screen/frames/latest", ctx=ctx)


@mcp.tool(
    name="feedling.screen.frames_list",
    description=(
        "List recent screen frame metadata (timestamp, app, OCR text) from the "
        "user's iOS device. Does NOT include image bytes — use latest_frame for "
        "image bytes of the newest frame. limit defaults to 20, max 100. "
        "Useful for 'what has the user been doing?' over a short window."
    ),
)
def screen_frames_list(limit: int = 20, ctx: Context = None) -> dict:
    return _get("/v1/screen/frames", {"limit": max(1, min(limit, 100))}, ctx=ctx)


@mcp.tool(
    name="feedling.screen.analyze",
    description=(
        "Get a structured analysis of the user's current screen activity: "
        "foreground app, OCR summary, and whether the push cooldown has elapsed."
    ),
)
def screen_analyze(ctx: Context = None) -> dict:
    return _get("/v1/screen/analyze", ctx=ctx)


@mcp.tool(
    name="feedling.screen.summary",
    description=(
        "Get today's screen-time rollup for the user (iOS + Mac): total minutes, "
        "top app, top category, pickups. Aggregated server-side from the last 24h "
        "of frames. Use for daily-report-style questions."
    ),
)
def screen_summary(ctx: Context = None) -> dict:
    return _get("/v1/screen/summary", ctx=ctx)


@mcp.tool(
    name="feedling.screen.decrypt_frame",
    description=(
        "Decrypt a screen-frame envelope and return the actual pixels + OCR "
        "text so the Agent can SEE the frame. Runs inside the enclave — the "
        "plaintext never leaves the TDX boundary except on the wire back to "
        "the authenticated caller. If frame_id is omitted, the most recent "
        "frame is used. Returns a list with the JPEG image (so vision "
        "activates) and a text block containing ocr_text + app + ts metadata."
    ),
)
def screen_decrypt_frame(
    frame_id: str = "",
    include_image: bool = True,
    ctx: Context = None,
) -> list:
    """Resolve a frame id (or pick the latest), ask the enclave to
    decrypt, and return an MCP content list the agent can consume:

        [ Image(jpeg_bytes, format="jpeg"),   # vision block
          "{json metadata with ocr_text}"     # text block ]

    If include_image is False, returns a dict with ocr_text + metadata
    only — useful when the caller just wants text and wants to avoid the
    bandwidth cost of shipping JPEG base64.
    """
    if not ENCLAVE_BASE:
        return [{"error": "enclave not configured — FEEDLING_ENCLAVE_URL missing"}]

    # Resolve frame_id lazily — empty means "latest".
    fid = (frame_id or "").strip()
    if not fid:
        try:
            listing = _get("/v1/screen/frames", {"limit": 1}, ctx=ctx)
        except httpx.HTTPError as e:
            return [{"error": f"frames_list_failed: {e}"}]
        frames = listing.get("frames") or []
        if not frames:
            return [{"error": "no frames on record yet"}]
        fid = frames[0].get("id") or ""
        if not fid:
            return [{"error": "latest frame has no id"}]

    try:
        with httpx.Client(timeout=30, verify=False) as client:
            r = client.get(
                f"{ENCLAVE_BASE}/v1/screen/frames/{fid}/decrypt",
                headers=_headers(ctx),
                params={"include_image": "true" if include_image else "false"},
            )
            r.raise_for_status()
            payload = r.json()
    except httpx.HTTPError as e:
        return [{"error": f"enclave_decrypt_failed: {e}", "frame_id": fid}]

    if payload.get("error"):
        return [payload]

    metadata = {k: v for k, v in payload.items() if k not in ("image_b64",)}
    if not include_image:
        return [metadata]

    img_b64 = payload.get("image_b64") or ""
    if not img_b64:
        return [{"warning": "decrypt ok but no image_b64 in plaintext", **metadata}]

    try:
        jpeg_bytes = base64.b64decode(img_b64)
    except Exception as e:
        return [{"error": f"image_b64_decode: {e}", **metadata}]

    print(f"[mcp] decrypt_frame id={fid} bytes={len(jpeg_bytes)} ocr_chars={len(metadata.get('ocr_text') or '')}")
    # FastMCP serializes list returns as a multi-block MCP tool result:
    # the Image becomes an ImageContent the agent's vision reads, and the
    # dict becomes structuredContent + a JSON-serialized text block.
    return [Image(data=jpeg_bytes, format="jpeg"), metadata]


# ---------------------------------------------------------------------------
# Chat tools
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling.chat.post_message",
    description=(
        "Post a message from the Agent into the Feedling iOS chat window. "
        "The user will see it immediately in the app."
    ),
)
def chat_post_message(content: str, ctx: Context = None) -> dict:
    """Agent posts a reply, always as a v1 envelope. The MCP process runs
    inside the enclave-compose boundary, so wrapping prerequisites
    (owner_user_id + both pubkeys) are always available by the time
    this tool is callable; if not, fail loud rather than regress to
    plaintext.
    """
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
    print(f"[mcp] chat.post_message v1 envelope id={envelope['id']}")
    return _post("/v1/chat/response", {"envelope": envelope}, ctx=ctx)


@mcp.tool(
    name="feedling.chat.get_history",
    description="Retrieve recent chat history between the user and the Agent.",
)
def chat_get_history(limit: int = 50, ctx: Context = None) -> dict:
    return _get_decrypted("/v1/chat/history", {"limit": min(limit, 200)}, ctx=ctx)


# ---------------------------------------------------------------------------
# Identity card
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling.identity.init",
    description=(
        "Initialize the Agent's identity card. Call this exactly once during bootstrap. "
        "Requires exactly 5 dimensions. Each dimension has a name (string), "
        "value (0-100), and description (string)."
    ),
)
def identity_init(
    agent_name: str,
    self_introduction: str,
    dimensions: list[dict],
    ctx: Context = None,
) -> dict:
    """Wrap the identity card into a v1 envelope before POSTing. MCP runs
    inside the enclave so wrapping prerequisites are always available;
    if they're not, fail loud rather than regress to plaintext.
    """
    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if not (user_id and user_pk is not None and enclave_pk is not None):
        return {"error": "cannot init identity — pubkeys unavailable"}
    inner = json.dumps({
        "agent_name": agent_name,
        "self_introduction": self_introduction,
        "dimensions": dimensions,
    }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    envelope = build_envelope(
        plaintext=inner,
        owner_user_id=user_id,
        user_pk_bytes=user_pk,
        enclave_pk_bytes=enclave_pk,
        visibility="shared",
    )
    print(f"[mcp] identity.init v1 envelope id={envelope['id']}")
    return _post("/v1/identity/init", {"envelope": envelope}, ctx=ctx)


@mcp.tool(
    name="feedling.identity.get",
    description="Retrieve the current identity card.",
)
def identity_get(ctx: Context = None) -> dict:
    return _get_decrypted("/v1/identity/get", ctx=ctx)


@mcp.tool(
    name="feedling.identity.nudge",
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

    inner = json.dumps({
        "agent_name": ident.get("agent_name", ""),
        "self_introduction": ident.get("self_introduction", ""),
        "dimensions": dims,
    }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
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
    name="feedling.memory.add_moment",
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
    name="feedling.memory.list",
    description="List moments in the memory garden, ordered by occurred_at descending.",
)
def memory_list(limit: int = 20, ctx: Context = None) -> dict:
    return _get_decrypted("/v1/memory/list", {"limit": limit}, ctx=ctx)


@mcp.tool(
    name="feedling.memory.get",
    description="Get a single moment by its id.",
)
def memory_get(id: str, ctx: Context = None) -> dict:
    return _get("/v1/memory/get", {"id": id}, ctx=ctx)


@mcp.tool(
    name="feedling.memory.delete",
    description="Delete a moment from the memory garden by its id.",
)
def memory_delete(id: str, ctx: Context = None) -> dict:
    return _delete("/v1/memory/delete", {"id": id}, ctx=ctx)


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------


@mcp.tool(
    name="feedling.bootstrap",
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
        # then run it with uvicorn.
        import uvicorn
        from starlette.middleware import Middleware as StarletteMW
        app = mcp.http_app(
            transport="sse",
            middleware=[StarletteMW(KeyCaptureMiddleware)],
        )
        if tls_on:
            uvicorn.run(app, host="0.0.0.0", port=port,
                        ssl_certfile=cert_path, ssl_keyfile=key_path,
                        log_level="info")
        else:
            uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
    else:
        mcp.run(transport=transport, host="0.0.0.0", port=port)
