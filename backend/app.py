from flask import Flask, jsonify, request
from datetime import datetime
import uuid

app = Flask(__name__)

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
    payload = request.get_json(silent=True) or {}
    print(f"[dynamic-island] {payload}")
    return jsonify({"status": "delivered", "push_id": f"pi_{uuid.uuid4().hex[:8]}"})


@app.route("/v1/push/live-activity", methods=["POST"])
def push_live_activity():
    payload = request.get_json(silent=True) or {}
    print(f"[live-activity] {payload}")
    activity_id = payload.get("activity_id", f"la_{uuid.uuid4().hex[:8]}")
    return jsonify({"status": "updated", "activity_id": activity_id})


@app.route("/v1/push/notification", methods=["POST"])
def push_notification():
    payload = request.get_json(silent=True) or {}
    print(f"[notification] {payload}")
    return jsonify({"status": "sent", "message_id": f"msg_{uuid.uuid4().hex[:8]}"})


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


if __name__ == "__main__":
    print("Feedling mock server running at http://localhost:5001")
    app.run(host="0.0.0.0", port=5001, debug=True)
