---
name: feedling
description: Read screen usage data from the user's iPhone and Mac via Feedling, and push notifications to iOS Dynamic Island, Live Activity, and push notifications.
homepage: https://feedling.app
metadata: {"openclaw":{"emoji":"📱","requires":{"env":["FEEDLING_API_URL","FEEDLING_API_KEY"]},"primaryEnv":"FEEDLING_API_KEY"}}
---

# Feedling Skill

Feedling is a screen-awareness layer. It captures what the user does on their iPhone (via PIP screen recording) and Mac (via screen monitoring), processes it into structured metadata, and exposes it through this API.

You are **not** Feedling. Feedling is just data + delivery. You decide what to do with the data — what to say, when to push, what tone to use. Feedling has no opinions about any of that.

## Environment

- `FEEDLING_API_URL` — Base URL of the Feedling backend (e.g. `http://localhost:5000`)
- `FEEDLING_API_KEY` — API key for authentication (sent as `X-API-Key` header)

## Heartbeat

On every heartbeat tick, call `GET /v1/screen/summary` to get a combined cross-device snapshot. Decide whether anything is worth acting on — a long streak of TikTok, a focus session ending, a context switch spike. You choose what matters.

---

## Read Endpoints

### GET /v1/screen/ios

iPhone screen usage for today.

**Request**
```
GET {FEEDLING_API_URL}/v1/screen/ios
X-API-Key: {FEEDLING_API_KEY}
```

**Response**
```json
{
  "date": "2026-04-11",
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
      "last_used": "22:31"
    },
    {
      "name": "YouTube",
      "bundle_id": "com.google.ios.youtube",
      "category": "Entertainment",
      "duration_minutes": 35,
      "sessions": 4,
      "first_used": "12:02",
      "last_used": "21:45"
    },
    {
      "name": "Instagram",
      "bundle_id": "com.burbn.instagram",
      "category": "Social",
      "duration_minutes": 28,
      "sessions": 8,
      "first_used": "09:30",
      "last_used": "22:10"
    },
    {
      "name": "Messages",
      "bundle_id": "com.apple.MobileSMS",
      "category": "Communication",
      "duration_minutes": 22,
      "sessions": 15,
      "first_used": "08:05",
      "last_used": "22:48"
    }
  ],
  "categories": {
    "Entertainment": 80,
    "Social": 28,
    "Communication": 37,
    "Browsing": 18,
    "Utility": 16
  }
}
```

---

### GET /v1/screen/mac

Mac screen usage for today.

**Request**
```
GET {FEEDLING_API_URL}/v1/screen/mac
X-API-Key: {FEEDLING_API_KEY}
```

**Response**
```json
{
  "date": "2026-04-11",
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
      "window_titles": ["Notion – feedling roadmap", "Linear – Sprint 3", "Figma Community"]
    },
    {
      "name": "Figma",
      "bundle_id": "com.figma.Desktop",
      "category": "Design",
      "duration_minutes": 95,
      "window_titles": ["Feedling iOS – v2 screens", "Component library"]
    },
    {
      "name": "Cursor",
      "bundle_id": "com.todesktop.230313mzl4w4u92",
      "category": "Development",
      "duration_minutes": 85,
      "window_titles": ["feedling-mcp-v1 – app.py", "feedling-ios – LiveActivity.swift"]
    },
    {
      "name": "Slack",
      "bundle_id": "com.tinyspeck.slackmacgap",
      "category": "Communication",
      "duration_minutes": 40,
      "window_titles": ["#design", "#eng", "DMs"]
    },
    {
      "name": "Zoom",
      "bundle_id": "us.zoom.xos",
      "category": "Communication",
      "duration_minutes": 45,
      "window_titles": ["Weekly sync"]
    }
  ],
  "categories": {
    "Browsing": 120,
    "Design": 95,
    "Development": 85,
    "Communication": 85,
    "Productivity": 10
  }
}
```

---

### GET /v1/screen/summary

Cross-device combined view. Use this on heartbeat.

**Request**
```
GET {FEEDLING_API_URL}/v1/screen/summary
X-API-Key: {FEEDLING_API_KEY}
```

**Response**
```json
{
  "date": "2026-04-11",
  "ios": {
    "total_screen_time_minutes": 179,
    "top_app": "TikTok",
    "top_category": "Entertainment",
    "pickups": 47
  },
  "mac": {
    "total_active_minutes": 395,
    "deep_work_minutes": 175,
    "focus_score": 72,
    "top_app": "Google Chrome",
    "context_switches": 34
  },
  "combined": {
    "total_screen_minutes": 574,
    "insight": "Heavy design + dev session on Mac. Phone usage mostly entertainment in evenings."
  }
}
```

---

### GET /v1/sources

Which data sources are connected and their sync status.

**Request**
```
GET {FEEDLING_API_URL}/v1/sources
X-API-Key: {FEEDLING_API_KEY}
```

**Response**
```json
{
  "sources": [
    {
      "id": "ios_pip",
      "name": "iPhone PIP Recording",
      "status": "connected",
      "last_sync": "2026-04-11T22:51:00Z",
      "device": "iPhone 16 Pro"
    },
    {
      "id": "mac_monitor",
      "name": "Mac Screen Monitor",
      "status": "connected",
      "last_sync": "2026-04-11T22:53:00Z",
      "device": "MacBook Pro M3"
    }
  ]
}
```

---

## Write Endpoints (iOS Push Delivery)

These endpoints let you push content to the user's iPhone. You decide what to say and when — Feedling handles the delivery.

### POST /v1/push/dynamic-island

Push a compact status update to the Dynamic Island.

**Request**
```
POST {FEEDLING_API_URL}/v1/push/dynamic-island
X-API-Key: {FEEDLING_API_KEY}
Content-Type: application/json

{
  "title": "3h on phone today",
  "subtitle": "mostly TikTok",
  "icon": "iphone"
}
```

**Response**
```json
{ "status": "delivered", "push_id": "pi_abc123" }
```

---

### GET /v1/screen/frames

List recently captured iPhone screen frames (metadata only, no image data).

**Request**
```
GET {FEEDLING_API_URL}/v1/screen/frames?limit=20
```

**Response**
```json
{
  "frames": [
    {
      "filename": "frame_1744123456789.jpg",
      "ts": 1744123456.789,
      "app": "com.zhiliaoapp.musically",
      "ocr_text": "For You\nTikTok video caption here...",
      "w": 960,
      "h": 2079,
      "url": "http://54.209.126.4:5001/v1/screen/frames/frame_1744123456789.jpg"
    }
  ],
  "total": 87
}
```

Use `ocr_text` to understand what the user is reading/watching without loading the image. Use `url` to load the actual image when you need visual context.

---

### GET /v1/screen/frames/latest

Get the single most recent frame, including the base64 image. Use this when you want to visually see what the user is currently doing.

**Request**
```
GET {FEEDLING_API_URL}/v1/screen/frames/latest
```

**Response**
```json
{
  "filename": "frame_1744123456789.jpg",
  "ts": 1744123456.789,
  "app": "com.zhiliaoapp.musically",
  "ocr_text": "For You\n...",
  "w": 960,
  "h": 2079,
  "url": "http://54.209.126.4:5001/v1/screen/frames/frame_1744123456789.jpg",
  "image_base64": "/9j/4AAQ..."
}
```

---

### GET /v1/push/tokens

List all registered push tokens. Call this first to get the current `activity_id` before sending a Live Activity push.

**Request**
```
GET {FEEDLING_API_URL}/v1/push/tokens
```

**Response**
```json
{
  "tokens": [
    { "type": "device", "token": "abc123...", "registered_at": "..." },
    { "type": "live_activity", "token": "def456...", "activity_id": "FE137E4B-...", "registered_at": "..." },
    { "type": "push_to_start", "token": "ghi789...", "registered_at": "..." }
  ]
}
```

---

### POST /v1/push/live-activity

Update the Live Activity shown on the Dynamic Island and lock screen. The `message` field is what gets displayed prominently — write whatever you want to say here. `topApp` and `screenTimeMinutes` are optional context shown in the corner.

**Workflow:** Call `GET /v1/push/tokens` first to get the current `activity_id`, then send this request.

**Request**
```
POST {FEEDLING_API_URL}/v1/push/live-activity
Content-Type: application/json

{
  "activity_id": "FE137E4B-A7E5-4B04-8527-7B1D2D6A56A9",
  "message": "你今天刷了 45 分钟 TikTok，差不多该歇一歇了。",
  "topApp": "TikTok",
  "screenTimeMinutes": 45
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `activity_id` | Yes | From `GET /v1/push/tokens` |
| `message` | Yes | What you want to say — shown prominently in expanded Dynamic Island |
| `topApp` | No | App name shown in corner (omit if not relevant) |
| `screenTimeMinutes` | No | Duration shown in corner (omit if not relevant) |

**Response**
```json
{ "status": "delivered", "activity_id": "FE137E4B-..." }
```

---

### POST /v1/push/notification

Send a push notification to the Feedling iOS app.

**Request**
```
POST {FEEDLING_API_URL}/v1/push/notification
X-API-Key: {FEEDLING_API_KEY}
Content-Type: application/json

{
  "title": "45 min on TikTok",
  "body": "That's your entertainment budget for today. Want to lock it?",
  "sound": "default",
  "badge": 1
}
```

**Response**
```json
{ "status": "sent", "message_id": "msg_xyz789" }
```
