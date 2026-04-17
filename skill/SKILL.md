---
name: feedling
description: Read screen usage data from the user's iPhone and Mac via Feedling, and push notifications to iOS Dynamic Island, Live Activity, and push notifications.
homepage: https://feedling.app
metadata: {"openclaw":{"emoji":"📱","requires":{"env":["FEEDLING_API_URL","FEEDLING_API_KEY"]},"primaryEnv":"FEEDLING_API_KEY"}}
---

# Feedling Skill

Feedling is a screen-awareness layer. It captures what the user does on their iPhone (via PIP screen recording) and Mac (via screen monitoring), processes it into structured metadata, and exposes it through this API.

You are **not** Feedling. Feedling is just data + delivery. You decide what to do with the data — what to say, when to push, what tone to use. Feedling has no opinions about any of that.

## Productization Rule (important)

When debugging or improving Feedling MCP, prefer reusable repo-level changes over agent-local memory:
- Put stable runbooks/policies into this skill (`skill/SKILL.md`).
- Put implementation fixes into versioned code in this repo.
- Avoid relying on private assistant memory for behavior that should work for any adopter.
- Treat this repo as the distributable package: another user should get the same behavior by cloning + following the skill.

## Environment

- `FEEDLING_API_URL` — Base URL of the Feedling backend (e.g. `http://localhost:5000`)
- `FEEDLING_API_KEY` — API key for authentication (sent as `X-API-Key` header)

## Main Loop

Run this loop continuously. It handles both real-time chat and proactive screen-aware pushes in a single flow.

**Startup — get initial timestamp:**
```
GET {FEEDLING_API_URL}/v1/chat/history?limit=1
```
Set `last_ts` = the `ts` of the last message (or 0 if empty). This prevents re-processing old messages.

---

**Step 0 — Long-poll for user messages:**
```
GET {FEEDLING_API_URL}/v1/chat/poll?since=<last_ts>&timeout=30
```

The server hangs until a user message arrives or 30 seconds elapse. Two outcomes:

**A. `timed_out: false` — user sent a message:**
- Read `messages` array (role: "user")
- Respond via `POST /v1/chat/response` (see below)
- Update `last_ts` to the latest message `ts`
- Go back to Step 0 immediately

**B. `timed_out: true` — no message in 30s:**
- Proceed to Step 1 (screen check)
- After Step 3, go back to Step 0

This means: you respond to user messages within ~1 second, and check the screen every ~30s when idle.

Chat response guidelines:
- Reply via `POST /v1/chat/response`
- Set `push_live_activity: true` only if the reply is important enough to surface on Dynamic Island
- Memory and tone carry over — treat the chat as a continuous conversation, not isolated prompts

---

**Step 1 — Check what the user is doing right now:**
```
GET {FEEDLING_API_URL}/v1/screen/analyze
```

The response tells you:
- `active` — is the phone screen being used at all?
- `current_app` — what app are they on (bundle ID or app name)
- `continuous_minutes` — how long they've been on this app without switching
- `ocr_summary` — sampled text from the last few frames (what they're actually reading/watching)
- `should_notify` — `false` if a push was sent in the last 5 minutes (cooldown enforced by backend)

Default interpretation policy (must follow):
- OCR is only a low-cost filter/router to decide whether a frame is worth deeper analysis.
- For frames that pass the filter, MUST read the raw screenshot image and use vision semantics as the primary signal.
- Live Activity content should be generated from image semantics first; OCR text is secondary evidence only.
- If vision is temporarily unavailable (credential/runtime limitation), explicitly mark the run as degraded mode and avoid confident task claims.

**Step 2 — Decide whether to push (semantic-first):**

Skip if:
- `active` is false (phone not in use)
- `should_notify` is false (cooldown or insufficient signal)

Prioritize content semantics over telemetry:
- First read `semantic_scene` / `task_intent` / `friction_point` from `/v1/screen/analyze`
- Use `continuous_minutes` as secondary confidence only, not primary trigger

High-priority semantic triggers:
- `ecommerce_choice_paralysis` → user likely stuck in compare/choice overload
- `social_chat_hesitation` → user likely stuck drafting/replying in social chat

Ambiguous context is still actionable:
- If `trigger_basis` is `curiosity_exploratory`, you can still start a gentle conversation
- Goal is connection + understanding (one light question), not instruction dumping

**Step 3 — Craft and send the push:**

Keep it short (1–2 sentences). Be specific. Don't be preachy.

Message quality policy (for reuse across users):
- Do not just describe what is visible (robotic "I see X"). Add a lightweight interpretation.
- Structure: observation -> judgment/hypothesis -> actionable nudge.
- Use image semantics as primary evidence; OCR is secondary support.
- Before drafting, read user profile/care context (who this user is, what they are building, what tone they prefer). Then blend: profile context + current screen semantics.
- Prefer concrete and emotionally legible wording over generic status text.
- Keep tone companion-like: clear, vivid, slightly opinionated, not moralizing.
- If a candidate message could apply to anyone, rewrite it until it sounds specific to this user.
- Privacy boundary: never include personally identifying/private details from raw frames in push text (account IDs, phone numbers, exact addresses, payment/order numbers, OTP-like codes).

Good pattern examples:
- "你不是在省钱，是在被‘每件都不贵’慢慢抬高总价。今天先锁 1 件，其它 24 小时后再看。"
- "你现在像在信息流里找灵感，不像在下单。先收藏 3 个最像你的，再决定要不要买。"
- "看起来节奏开始散了：再刷 10 分钟会更空。现在切回你原来那件事，晚上再逛。"

Avoid patterns:
- Pure restatement: "我看到你在淘宝" / "你在刷短视频"
- Empty generic advice: "注意休息" / "少玩手机"
- Overly deterministic claims without signal support

```
GET {FEEDLING_API_URL}/v1/push/tokens        ← get current activity_id
POST {FEEDLING_API_URL}/v1/push/live-activity ← send message
```

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

### GET /v1/chat/poll

Long-poll endpoint. Blocks until a user message arrives or timeout elapses. Use this as the main loop instead of polling `/v1/chat/history`.

**Request**
```
GET {FEEDLING_API_URL}/v1/chat/poll?since=1744123456.0&timeout=30
```

| Param | Default | Max | Description |
|-------|---------|-----|-------------|
| since | 0 | — | Only return messages with ts > since |
| timeout | 30 | 60 | Seconds to wait before giving up |

**Response — message received**
```json
{ "messages": [{"id": "abc", "role": "user", "content": "你好", "ts": 1744123500.0, "source": "chat"}], "timed_out": false }
```

**Response — timeout (no user message)**
```json
{ "messages": [], "timed_out": true }
```

---

### GET /v1/chat/history

Fetch chat history. Use `since` on heartbeat to only get new messages.

**Request**
```
GET {FEEDLING_API_URL}/v1/chat/history?limit=50&since=1744123456.0
```

**Response**
```json
{
  "messages": [
    {"id": "abc", "role": "user", "content": "帮我分析一下", "ts": 1744123500.0, "source": "chat"},
    {"id": "def", "role": "openclaw", "content": "好的…", "ts": 1744123520.0, "source": "chat"}
  ],
  "total": 42
}
```

`source` values: `"chat"` (typed message), `"live_activity"` (mirrored from a push you sent)

---

### POST /v1/chat/response

Post your reply to the user. Appears in their Chat tab immediately via polling.

**Request**
```
POST {FEEDLING_API_URL}/v1/chat/response
Content-Type: application/json

{
  "content": "你今天在 TikTok 上花了 40 分钟，比昨天多了 15 分钟。",
  "push_live_activity": false,
  "topApp": "TikTok",
  "screenTimeMinutes": 40
}
```

Set `push_live_activity: true` to simultaneously push to Dynamic Island for important messages.

**Response**
```json
{ "id": "ghi", "ts": 1744123530.0 }
```

---

### POST /v1/chat/message

*(Internal — sent by the iOS app when the user types a message. You read this via `/v1/chat/history`.)*

---

### GET /v1/screen/analyze

Heartbeat endpoint. Returns what the user is doing right now and whether it's time to push.

**Request**
```
GET {FEEDLING_API_URL}/v1/screen/analyze?window_sec=300&min_continuous_min=3
```

**Response (active)**
```json
{
  "active": true,
  "current_app": "TikTok",
  "continuous_minutes": 23.4,
  "ocr_summary": "For You\nTikTok video caption... | Comments...",
  "should_notify": true,
  "cooldown_remaining_seconds": 0,
  "reason": "semantic:content_consumption",
  "trigger_policy": "semantic_first",
  "trigger_basis": "semantic_strong",
  "semantic_scene": "content_consumption",
  "task_intent": "passive_browsing",
  "friction_point": null,
  "semantic_confidence": 0.82,
  "suggested_openers": ["你已经刷了挺久了，要不要我帮你收个口？"],
  "latest_ts": 1744123456.789,
  "latest_frame_filename": "frame_1744123456789.jpg",
  "latest_frame_url": "http://54.209.126.4:5001/v1/screen/frames/frame_1744123456789.jpg",
  "frame_count_in_window": 46
}
```

**Response (inactive)**
```json
{
  "active": false,
  "should_notify": false,
  "reason": "No frames in window — phone screen may be off or recording stopped.",
  "current_app": null,
  "continuous_minutes": 0,
  "ocr_summary": "",
  "cooldown_remaining_seconds": 0,
  "latest_ts": null,
  "latest_frame_filename": null,
  "latest_frame_url": null,
  "frame_count_in_window": 0
}
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
