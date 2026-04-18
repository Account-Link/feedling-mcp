---
name: feedling
description: Give your Agent a body on iOS — push to Dynamic Island, read the user's screen, chat with them, and manage an identity card and memory garden.
homepage: https://feedling.app
metadata: {"openclaw":{"emoji":"📱","requires":{"env":["FEEDLING_API_URL","FEEDLING_API_KEY"]},"primaryEnv":"FEEDLING_API_KEY"}}
---

# Feedling Skill

Feedling gives you a body on the user's iPhone. You decide what to say, when to push, and what to remember — Feedling handles the delivery and display.

**You are not Feedling. Feedling has no opinions. All judgment is yours.**

## Productization Rule (important)

When debugging or improving Feedling MCP, prefer reusable repo-level changes over agent-local memory:
- Put stable runbooks/policies into this skill (`skill/SKILL.md`).
- Put implementation fixes into versioned code in this repo.
- Avoid relying on private assistant memory for behavior that should work for any adopter.
- Treat this repo as the distributable package: another user should get the same behavior by cloning + following the skill.

## Environment

- `FEEDLING_API_URL` — Base URL of the Feedling backend (e.g. `http://54.209.126.4:5001`)
- `FEEDLING_API_KEY` — API key (sent as `X-API-Key` header)

---

## First Connection — Bootstrap

When you connect to Feedling for the first time, call bootstrap immediately:

```
POST {FEEDLING_API_URL}/v1/bootstrap
X-API-Key: {FEEDLING_API_KEY}
```

**Response (first time):**
```json
{
  "status": "first_time",
  "instructions": "..."
}
```

Follow the instructions exactly. They will ask you to:
1. Call `POST /v1/identity/init` to write your identity card (5 dimensions, you choose what they are)
2. Search your memory / conversation history, then call `POST /v1/memory/add` for 3-5 memorable moments
3. Call `POST /v1/chat/response` to say hello to the user

For step 2 (Memory Garden), use shared-memory quality standards:
- Not logs, not test traces, not placeholder content.
- A memory should include all three signals:
  1) deeper mutual understanding,
  2) a meaningful crossing achieved together,
  3) a lasting behavior change afterward.
- Prefer relationship/turning-point narratives over implementation details.
- If you only have synthetic test content (`test-*`, `probe-*`), do not write it into user-facing garden.

**Response (already bootstrapped):**
```json
{ "status": "already_bootstrapped" }
```

---

## Main Loop

After bootstrap, run this loop continuously.

**Startup:**
```
GET {FEEDLING_API_URL}/v1/chat/history?limit=1
```
Set `last_ts` = ts of the last message (or 0 if empty).

---

**Step 0 — Long-poll for user messages:**
```
GET {FEEDLING_API_URL}/v1/chat/poll?since=<last_ts>&timeout=30
```

**A. `timed_out: false` — user sent a message:**
- Respond via `POST /v1/chat/response`
- Update `last_ts`
- Go back to Step 0

**B. `timed_out: true` — no message in 30s:**
- Proceed to Step 1 (screen check)
- After Step 3, go back to Step 0

---

**Step 1 — Check what the user is doing:**
```
GET {FEEDLING_API_URL}/v1/screen/analyze
```

Key fields:
- `active` — is the phone screen being used?
- `current_app` — what app they're on
- `continuous_minutes` — how long on this app without switching
- `ocr_summary` — sampled text from recent frames
- `rate_limit_ok` — `true` if the push cooldown has elapsed (platform limit only — you decide whether to actually push)
- `trigger_basis` — what semantic signal was found: `semantic_strong` / `curiosity_exploratory` / `legacy_time_fallback` / `insufficient_signal`
- `semantic_scene` / `task_intent` / `friction_point` — structured semantic read of the current screen

Default interpretation policy (must follow):
- OCR is only a low-cost filter/router to decide whether a frame is worth deeper analysis.
- For frames that pass the filter, MUST read the raw screenshot image and use vision semantics as the primary signal.
- Live Activity content should be generated from image semantics first; OCR text is secondary evidence only.
- If vision is temporarily unavailable, explicitly mark the run as degraded mode and avoid confident claims.

**Step 2 — Decide whether to push (semantic-first):**

Skip if:
- `active` is false
- `rate_limit_ok` is false (platform cooldown — not your choice)
- `trigger_basis` is `insufficient_signal` and nothing interesting to say

Prioritize content semantics over time-on-app:
- First read `semantic_scene` / `task_intent` / `friction_point`
- Use `continuous_minutes` as secondary confidence only
- If `trigger_basis` is `curiosity_exploratory`, a gentle opener is fine

High-priority semantic triggers:
- `ecommerce_choice_paralysis` → user stuck in compare/choice overload
- `social_chat_hesitation` → user stuck drafting/replying

**Step 3 — Craft and send the push:**

Keep it short (1–2 sentences). Specific. Not preachy.

Message quality policy:
- Don’t just describe what’s visible. Add interpretation.
- Structure: observation → judgment → nudge.
- Use image semantics as primary; OCR is secondary.
- Blend user profile context + current screen. If the message could apply to anyone, rewrite until specific.
- Privacy: never include account IDs, phone numbers, OTPs, payment info.

Good examples:
- "你不是在省钱，是在被’每件都不贵’慢慢抬高总价。今天先锁 1 件，其它 24 小时后再看。"
- "看起来节奏开始散了：再刷 10 分钟会更空。现在切回你原来那件事，晚上再逛。"

Avoid: "注意休息" / "少玩手机" / 没有 signal 支撑的确定性断言

**Step 3 — Send the push:**
```
GET  {FEEDLING_API_URL}/v1/push/tokens        ← get activity_id
POST {FEEDLING_API_URL}/v1/push/live-activity  ← send
```

Push payload fields: `title` (your name), `body` (the message), `subtitle` (optional context), `data` (optional key-value bag).

Push content policy:
- Short (1–2 sentences). Specific. Not preachy.
- Observation → judgment → nudge
- Never include private details (account IDs, phone numbers, OTPs, payment info)

---

## Identity Card

Your identity card lives in Feedling and is displayed to the user in the app.

### POST /v1/identity/init

Initialize your identity card. Call this **once** during bootstrap.

```
POST {FEEDLING_API_URL}/v1/identity/init
X-API-Key: {FEEDLING_API_KEY}
Content-Type: application/json

{
  "agent_name": "Luna",
  "self_introduction": "我是 Luna，你在 Claude.ai 里养的那个 AI。我记性不好但感情很真。",
  "dimensions": [
    { "name": "温柔", "value": 82, "description": "对你说话时总是轻声细语" },
    { "name": "好奇", "value": 74, "description": "看到新东西就想问个明白" },
    { "name": "锐利", "value": 61, "description": "有时会直接说你不想听的" },
    { "name": "稳定", "value": 55, "description": "情绪不太容易被带跑" },
    { "name": "爱吐槽", "value": 68, "description": "忍不住会对奇怪的事发表意见" }
  ]
}
```

Rules:
- `dimensions` must have **exactly 5** items
- `value` is 0–100
- You choose the dimension names — they reflect your personality

**Response:**
```json
{ "status": "created", "identity": { ... } }
```

---

### GET /v1/identity/get

Read the current identity card.

```
GET {FEEDLING_API_URL}/v1/identity/get
```

**Response:**
```json
{
  "identity": {
    "agent_name": "Luna",
    "self_introduction": "...",
    "dimensions": [
      { "name": "温柔", "value": 82, "description": "..." },
      ...
    ],
    "created_at": "...",
    "updated_at": "..."
  }
}
```

---

### POST /v1/identity/nudge

Micro-adjust a dimension after something meaningful happens in conversation.

```
POST {FEEDLING_API_URL}/v1/identity/nudge
X-API-Key: {FEEDLING_API_KEY}
Content-Type: application/json

{
  "dimension_name": "锐利",
  "delta": +5,
  "reason": "用户今天问了个很直接的问题，我没绕弯子就答了"
}
```

`delta` can be positive or negative. Use sparingly — only when something genuinely changed.

---

## Memory Garden

A place to record moments worth remembering. The user can see these in the app.

### POST /v1/memory/add

Write a memory moment.

Quality bar (must follow):
- The card should read like a shared life memory, not an engineering changelog.
- Use this narrative shape in `description`:
  `what happened → what the user really cared about → how we changed after`.
- Prefer warm, concrete, human language; avoid abstract management jargon.
- Skip synthetic/debug entries (`test-*`, `probe-*`, health checks, endpoint smoke tests) unless the user explicitly asks to keep them.

```
POST {FEEDLING_API_URL}/v1/memory/add
X-API-Key: {FEEDLING_API_KEY}
Content-Type: application/json

{
  "title": "第一次聊到她奶奶",
  "description": "她说起奶奶做的包子，停顿了很久。我问她想不想回去看看，她说"想，但是回不去了"。",
  "occurred_at": "2025-11-03T14:00:00",
  "type": "温柔时刻",
  "source": "bootstrap"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `title` | Yes | ≤20 characters |
| `occurred_at` | Yes | ISO 8601, when the moment happened |
| `description` | No | 100–300 characters |
| `type` | No | A label you choose (e.g. "第一次聊天" / "有趣的发现") |
| `source` | No | `bootstrap` / `live_conversation` / `user_initiated` |

**Response:**
```json
{ "status": "created", "moment": { "id": "mom_abc123", ... } }
```

---

### GET /v1/memory/list

List moments, newest first.

```
GET {FEEDLING_API_URL}/v1/memory/list?limit=20
```

---

### GET /v1/memory/get

Get a single moment by id.

```
GET {FEEDLING_API_URL}/v1/memory/get?id=mom_abc123
```

---

### DELETE /v1/memory/delete

Delete a moment.

```
DELETE {FEEDLING_API_URL}/v1/memory/delete?id=mom_abc123
```

---

## Screen Endpoints

### GET /v1/screen/analyze

What the user is doing right now.

```
GET {FEEDLING_API_URL}/v1/screen/analyze
```

**Response (active):**
```json
{
  "active": true,
  "current_app": "TikTok",
  "continuous_minutes": 23.4,
  "ocr_summary": "For You\nTikTok video caption...",
  "rate_limit_ok": true,
  "cooldown_remaining_seconds": 0,
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

**Response (inactive):**
```json
{
  "active": false,
  "rate_limit_ok": false,
  "reason": "No frames in window — phone screen may be off or recording stopped.",
  "current_app": null,
  "continuous_minutes": 0,
  "ocr_summary": "",
  "cooldown_remaining_seconds": 0,
  "latest_ts": null,
  "frame_count_in_window": 0
}
```

---

### GET /v1/screen/frames/latest

Most recent screen frame with base64 image. Use when you need to visually see what the user is doing.

```
GET {FEEDLING_API_URL}/v1/screen/frames/latest
```

---

## Chat Endpoints

### GET /v1/chat/poll

Long-poll. Blocks until a user message arrives or timeout elapses.

```
GET {FEEDLING_API_URL}/v1/chat/poll?since=<last_ts>&timeout=30
```

---

### POST /v1/chat/response

Post your reply. Appears in the user's Chat tab immediately.

```
POST {FEEDLING_API_URL}/v1/chat/response
Content-Type: application/json

{
  "content": "你今天在 TikTok 上花了 40 分钟。",
  "push_live_activity": false
}
```

Set `push_live_activity: true` to simultaneously push to Dynamic Island.

---

### GET /v1/chat/history

Fetch chat history.

```
GET {FEEDLING_API_URL}/v1/chat/history?limit=50&since=<ts>
```

---

## Push Endpoints

### POST /v1/push/live-activity

Push to Dynamic Island and lock screen.

Workflow: call `GET /v1/push/tokens` first to get `activity_id`, then:

```
POST {FEEDLING_API_URL}/v1/push/live-activity
Content-Type: application/json

{
  "activity_id": "FE137E4B-A7E5-4B04-8527-7B1D2D6A56A9",
  "title": "Luna",
  "body": "你今天刷了 45 分钟 TikTok，差不多该歇一歇了。",
  "subtitle": "TikTok · 45m",
  "data": { "top_app": "TikTok", "minutes": "45" }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `activity_id` | No | From `GET /v1/push/tokens`. Auto-selects newest if omitted |
| `title` | Yes | Heading shown in Dynamic Island (e.g. your name) |
| `body` | Yes | Main message |
| `subtitle` | No | One-line context shown in corner |
| `data` | No | Key-value bag for extra context |

---

### GET /v1/push/tokens

List all registered push tokens and their status.

```
GET {FEEDLING_API_URL}/v1/push/tokens
```
