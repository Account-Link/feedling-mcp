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

Single-user / self-hosted mode: set `SINGLE_USER=true` on the backend and use
any key (the backend will accept unauthenticated requests), or set
`FEEDLING_API_KEY=<shared>` on both sides.
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
from fastmcp.server.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.types import ASGIApp

from content_encryption import build_envelope

FLASK_BASE = os.environ.get("FEEDLING_FLASK_URL", "http://127.0.0.1:5001")
# When set, MCP routes content reads (chat history, memory list,
# identity get) through the enclave's decrypt endpoints so agents see
# plaintext rather than ciphertext. When unset (dev / self-hosted
# without an enclave), MCP calls Flask directly — v0 items come back
# plaintext, v1 items come back as opaque envelopes.
# verify=False on these calls because the enclave's TLS cert is
# self-signed; trust is REPORT_DATA-pinned from outside, not a PKI
# property of the in-cluster hop.
ENCLAVE_BASE = os.environ.get("FEEDLING_ENCLAVE_URL", "").rstrip("/")
FALLBACK_API_KEY = os.environ.get("FEEDLING_API_KEY", "").strip()
SINGLE_USER = os.environ.get("SINGLE_USER", "true").lower() == "true"

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
    (pre-v1 user with no uploaded pubkey, or no reachable enclave). The
    caller should fall back to plaintext write in that case so agents
    can still use the tool end-to-end.
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
    name="feedling.screen.analyze",
    description=(
        "Get a structured analysis of the user's current screen activity: "
        "foreground app, OCR summary, and whether the push cooldown has elapsed."
    ),
)
def screen_analyze(ctx: Context = None) -> dict:
    return _get("/v1/screen/analyze", ctx=ctx)


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
    """Agent posts a reply. Phase C part 3: wrap into a v1 envelope when
    pubkeys are available so the message lands as ciphertext on disk.
    Falls back to v0 plaintext when no enclave is reachable (self-hosted
    without a TEE).
    """
    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if user_id and user_pk is not None and enclave_pk is not None:
        envelope = build_envelope(
            plaintext=content.encode("utf-8"),
            owner_user_id=user_id,
            user_pk_bytes=user_pk,
            enclave_pk_bytes=enclave_pk,
            visibility="shared",
        )
        print(f"[mcp] chat.post_message v1 envelope id={envelope['id']}")
        return _post("/v1/chat/response", {"envelope": envelope}, ctx=ctx)
    print("[mcp] chat.post_message v0 plaintext (no pubkeys)")
    return _post("/v1/chat/response", {"content": content}, ctx=ctx)


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
    """Wrap the identity card into a v1 envelope before POSTing when
    wrapping prerequisites are available. Same pattern + fallback rules
    as `feedling.memory.add_moment`.

    Note: `feedling.identity.nudge` stays plaintext for now — in-place
    mutation of an encrypted card requires a decrypt-mutate-rewrap
    dance, which is cleanly solved by Phase C (MCP in TEE) and left
    for that cut. See `docs/NEXT.md`.
    """
    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if user_id and user_pk is not None and enclave_pk is not None:
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

    print("[mcp] identity.init v0 plaintext (no user/enclave pubkey available)")
    return _post("/v1/identity/init", {
        "agent_name": agent_name,
        "self_introduction": self_introduction,
        "dimensions": dimensions,
    }, ctx=ctx)


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
    """Phase C part 3: on v1 cards, MCP orchestrates the
    decrypt → mutate → rewrap → replace dance. On v0 cards, falls
    through to the legacy plaintext `/v1/identity/nudge` endpoint.

    Flow for v1:
      1. GET /v1/identity/get on the ENCLAVE (returns decrypted card).
      2. Find the matching dimension, clamp `value += delta` to [0, 100],
         record `last_nudge_reason`.
      3. Re-build the card envelope with `build_envelope`.
      4. POST /v1/identity/replace on the backend.

    Plaintext is confined to the MCP process inside the enclave-compose
    boundary. Server-side storage stays ciphertext throughout.
    """
    # Try the v0 path first. If the card is v0 or not yet initialized,
    # the legacy nudge endpoint handles it. The backend returns 409
    # with error="nudge_not_supported_on_v1_cards_yet" on v1 cards —
    # catch that specifically and fall through.
    try:
        return _post("/v1/identity/nudge", {
            "dimension_name": dimension_name,
            "delta": delta,
            "reason": reason,
        }, ctx=ctx)
    except httpx.HTTPStatusError as e:
        if e.response.status_code != 409:
            raise
        # 409 ⇒ v1 card. Fall through to the rewrap path.
        try:
            body = e.response.json()
            if body.get("error") != "nudge_not_supported_on_v1_cards_yet":
                raise
        except ValueError:
            raise
    return _identity_nudge_v1(dimension_name, delta, reason, ctx)


def _identity_nudge_v1(dimension_name: str, delta: int, reason: str, ctx) -> dict:
    """Separate helper so the caller can catch 409 from v0 and fall in."""
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
    """Wrap the memory moment into a v1 envelope before POSTing when the
    backend returns the keys we need.

    Plaintext fields stay plaintext on the wire only while the MCP
    process is on the VPS (Phase A). Once MCP moves into the enclave
    (Phase C), plaintext never leaves the TEE boundary. See
    `docs/NEXT.md` for the migration plan.

    Fallback: if the caller doesn't have a content pubkey uploaded
    (pre-v1 registration) or the enclave is unreachable, the tool
    reverts to the v0 plaintext POST so agents never lose write
    capability mid-session.
    """
    user_id, user_pk, enclave_pk = _whoami_pubkeys(ctx=ctx)
    if user_id and user_pk is not None and enclave_pk is not None:
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

    # v0 plaintext fallback — keep the tool usable even when
    # v1 prerequisites aren't in place (self-hosted, fresh register).
    print("[mcp] memory.add v0 plaintext (no user/enclave pubkey available)")
    return _post("/v1/memory/add", {
        "title": title,
        "description": description,
        "occurred_at": occurred_at,
        "type": type,
        "source": source,
    }, ctx=ctx)


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


def _materialize_tls_cert() -> tuple[str | None, str | None]:
    """Phase C: derive the same dstack-KMS-bound TLS cert that enclave_app.py
    uses on port 5003, write cert + key to transient tempfiles (tmpfs in
    the CVM), and return the paths. Returns (None, None) when
    FEEDLING_MCP_TLS is unset, so local dev stays HTTP.
    """
    if os.environ.get("FEEDLING_MCP_TLS", "false").lower() != "true":
        return (None, None)
    # Match enclave_app's "don't use empty string as simulator endpoint" hygiene.
    if os.environ.get("DSTACK_SIMULATOR_ENDPOINT", "") == "":
        os.environ.pop("DSTACK_SIMULATOR_ENDPOINT", None)
    # Import dstack_sdk lazily so local-dev-without-TLS doesn't pay for it.
    from dstack_sdk import DstackClient
    from dstack_tls import derive_tls_cert_and_key

    dstack = DstackClient()
    tls = derive_tls_cert_and_key(dstack)
    cert_file = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
    key_file = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
    cert_file.write(tls["cert_pem"]); cert_file.flush(); cert_file.close()
    key_file.write(tls["key_pem"]); key_file.flush(); key_file.close()
    return (cert_file.name, key_file.name)


if __name__ == "__main__":
    port = int(os.environ.get("FEEDLING_MCP_PORT", 5002))
    transport = os.environ.get("FEEDLING_MCP_TRANSPORT", "sse").lower()
    cert_path, key_path = _materialize_tls_cert()
    tls_on = cert_path is not None
    scheme = "https" if tls_on else "http"
    print(f"Feedling MCP server: transport={transport} port={port} scheme={scheme} "
          f"flask={FLASK_BASE} single_user={SINGLE_USER}")

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
