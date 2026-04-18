#!/usr/bin/env python3
"""
Feedling MCP Server — wraps the Flask backend as a FastMCP Streamable HTTP server.

Architecture:
  Claude.ai / Claude Desktop / OpenClaw  →  mcp_server.py (port 5002, MCP protocol)
  iOS App                                →  app.py (port 5001, HTTP REST)

All tool implementations call app.py on localhost:5001.
Run with: python mcp_server.py
"""

import os
import httpx
from fastmcp import FastMCP

FLASK_BASE = os.environ.get("FEEDLING_FLASK_URL", "http://127.0.0.1:5001")
API_KEY = os.environ.get("FEEDLING_API_KEY", "mock-key")

mcp = FastMCP(
    name="Feedling",
    instructions=(
        "Feedling gives your Agent a body on iOS. "
        "Use these tools to push to Dynamic Island, read the user's screen, "
        "chat with the user, manage the identity card, and tend the memory garden. "
        "Start with feedling.bootstrap on first connection."
    ),
)


def _headers() -> dict:
    return {"X-API-Key": API_KEY, "Content-Type": "application/json"}


def _get(path: str, params: dict | None = None) -> dict:
    with httpx.Client(timeout=15) as client:
        r = client.get(f"{FLASK_BASE}{path}", params=params, headers=_headers())
        r.raise_for_status()
        return r.json()


def _post(path: str, body: dict) -> dict:
    with httpx.Client(timeout=15) as client:
        r = client.post(f"{FLASK_BASE}{path}", json=body, headers=_headers())
        r.raise_for_status()
        return r.json()


def _delete(path: str, params: dict | None = None) -> dict:
    with httpx.Client(timeout=15) as client:
        r = client.delete(f"{FLASK_BASE}{path}", params=params, headers=_headers())
        r.raise_for_status()
        return r.json()


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
        "data is a free-form key-value bag (e.g. {\"top_app\": \"TikTok\", \"minutes\": \"45\"}). "
        "The platform enforces a cooldown — check feedling.screen.analyze rate_limit_ok before pushing."
    ),
)
def push_dynamic_island(
    title: str,
    body: str,
    subtitle: str = "",
    data: dict | None = None,
    event: str = "update",
) -> dict:
    return _post("/v1/push/dynamic-island", {
        "title": title,
        "body": body,
        "subtitle": subtitle or None,
        "data": data or {},
        "event": event,
    })


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
) -> dict:
    return _post("/v1/push/live-activity", {
        "title": title,
        "body": body,
        "subtitle": subtitle or None,
        "data": data or {},
        "event": event,
    })


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
def screen_latest_frame() -> dict:
    return _get("/v1/screen/frames/latest")


@mcp.tool(
    name="feedling.screen.analyze",
    description=(
        "Get a structured analysis of the user's current screen activity: "
        "foreground app, OCR summary, and whether the push cooldown has elapsed."
    ),
)
def screen_analyze() -> dict:
    return _get("/v1/screen/analyze")


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
def chat_post_message(content: str) -> dict:
    return _post("/v1/chat/response", {"content": content})


@mcp.tool(
    name="feedling.chat.get_history",
    description="Retrieve recent chat history between the user and the Agent.",
)
def chat_get_history(limit: int = 50) -> dict:
    return _get("/v1/chat/history", {"limit": min(limit, 200)})


# ---------------------------------------------------------------------------
# Identity card tools
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
) -> dict:
    return _post("/v1/identity/init", {
        "agent_name": agent_name,
        "self_introduction": self_introduction,
        "dimensions": dimensions,
    })


@mcp.tool(
    name="feedling.identity.get",
    description="Retrieve the current identity card.",
)
def identity_get() -> dict:
    return _get("/v1/identity/get")


@mcp.tool(
    name="feedling.identity.nudge",
    description=(
        "Micro-adjust a single dimension on the identity card. "
        "delta can be positive or negative (e.g. +5 or -3). "
        "Include a reason so the history is meaningful."
    ),
)
def identity_nudge(dimension_name: str, delta: int, reason: str = "") -> dict:
    return _post("/v1/identity/nudge", {
        "dimension_name": dimension_name,
        "delta": delta,
        "reason": reason,
    })


# ---------------------------------------------------------------------------
# Memory garden tools
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
) -> dict:
    return _post("/v1/memory/add", {
        "title": title,
        "description": description,
        "occurred_at": occurred_at,
        "type": type,
        "source": source,
    })


@mcp.tool(
    name="feedling.memory.list",
    description="List moments in the memory garden, ordered by occurred_at descending.",
)
def memory_list(limit: int = 20) -> dict:
    return _get("/v1/memory/list", {"limit": limit})


@mcp.tool(
    name="feedling.memory.get",
    description="Get a single moment by its id.",
)
def memory_get(id: str) -> dict:
    return _get("/v1/memory/get", {"id": id})


@mcp.tool(
    name="feedling.memory.delete",
    description="Delete a moment from the memory garden by its id.",
)
def memory_delete(id: str) -> dict:
    return _delete("/v1/memory/delete", {"id": id})


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
def bootstrap() -> dict:
    return _post("/v1/bootstrap", {})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("FEEDLING_MCP_PORT", 5002))
    print(f"Feedling MCP server running on port {port}")
    mcp.run(transport="streamable-http", host="0.0.0.0", port=port)
