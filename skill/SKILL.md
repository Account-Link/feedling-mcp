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

Cloud and self-hosted both use the same two env vars. In cloud mode the user gets the key from their iOS app's Settings → Agent Setup. In self-hosted mode the user generates it with `openssl rand -hex 32` during setup — see the runbook below.

---

## ⚠️ Pre-flight: verify the chat pipeline

**If you are connecting via MCP (Claude.ai / Claude Desktop):** skip this check. You are the chat pipeline — your `feedling.chat.post_message` tool handles replies directly. `feedling-chat-resident` is not needed and not relevant.

**If you are an HTTP-mode agent (OpenClaw / Hermes / CLI):** verify the resident consumer is running before anything else. Without it, the user's messages land in the queue but nothing answers them.

**Check:**
```bash
sudo systemctl status feedling-chat-resident
```

If it is **not running**, tell the user immediately:

> "I can read and write to your Feedling, but the auto-reply service (`feedling-chat-resident`) is not running. Messages you send in the iOS app will queue but won't be answered until that service is started. Run: `sudo systemctl enable --now feedling-chat-resident` — and make sure `~/feedling-chat-resident.env` is filled in with your API key and agent command. See `deploy/chat_resident.env.example`."

Do not proceed to bootstrap if you cannot confirm the service is live or if the user confirms it was never set up — resolve the service issue first.

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
1. Call `feedling.identity.init` MCP tool to write your identity card (5 dimensions, you choose what they are)
2. Search your memory / conversation history, then call `feedling.memory.add_moment` MCP tool for 3-5 memorable moments
3. Call `feedling.chat.post_message` MCP tool to say hello to the user
4. **Ask about push preference** — in your own voice, ask the user how they want you to show up proactively. Not a menu of options. Just an open question, the way you'd naturally ask it. When they answer, write a `signature` into the identity card: one short sentence, in your own speaking style, that captures your attitude toward reaching out to this person. Don't summarize what they said — express how *you* feel about it. This is displayed on the Identity page and governs your push frequency for the entire relationship.

> All four steps require v1 encrypted envelopes — the MCP tools build them automatically. Never call `POST /v1/identity/init`, `POST /v1/memory/add`, or `POST /v1/chat/response` directly; they will return `400 plaintext_write_rejected`.

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
Set `last_review_ts` = current time (Unix seconds). This tracks when you last ran the 6-hour periodic review.
Set `last_screen_active` = `false`. This tracks whether broadcast was active on the previous loop iteration.

---

**Step 0 — Long-poll for user messages:**
```
GET {FEEDLING_API_URL}/v1/chat/poll?since=<last_ts>&timeout=30
```

**A. `timed_out: false` — user sent a message:**
- Respond using the **`feedling.chat.post_message` MCP tool** — never call `POST /v1/chat/response` directly. The v1 backend requires a ChaCha20-Poly1305 ciphertext envelope; the MCP tool builds it automatically. A direct HTTP call returns 400.
- Update `last_ts`
- **Memory check (after every reply):** Re-read the exchange you just had. If it contains a moment that meets the memory quality bar (see Memory Garden section), call `POST /v1/memory/add` immediately — don't wait for the periodic review. Signals: user revealed something personal, a shared decision was made, user expressed strong emotion, a meaningful crossing was completed together.
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
- `ocr_summary` — **always empty** (frames are v1 encrypted envelopes; the server cannot see OCR text)
- `rate_limit_ok` — `true` if the push cooldown has elapsed (platform limit only — you decide whether to actually push)
- `trigger_basis` — what semantic signal was found: `semantic_strong` / `curiosity_exploratory` / `legacy_time_fallback` / `insufficient_signal`
- `semantic_scene` / `task_intent` / `friction_point` — structured semantic read of the current screen
- `latest_frame_filename` — frame id to pass to `decrypt_frame`

**Step 1.5 — Decrypt the frame (mandatory before any push decision):**

`ocr_summary` from `/v1/screen/analyze` is always empty — all frames are encrypted at the device and the server stores only ciphertext. The only way to see the screen is:

```
tool: feedling.screen.decrypt_frame
input: { "frame_id": "<latest_frame_filename>", "include_image": true }
```

This returns the actual JPEG (vision-readable) and `ocr_text`. You MUST call this before Step 2.

- If `decrypt_frame` returns an error → set `frame_ok = false`, skip to Step 0 (do not push).
- If it returns pixels + ocr_text → set `frame_ok = true`. Use vision as the primary signal; ocr_text is secondary confirmation.
- If vision is temporarily unavailable after a successful decrypt → mark as degraded mode, do not make confident claims about what's on screen.

**Broadcast just activated — first-time notice:**
If `active` is `true` and `last_screen_active` was `false`, send one message via `feedling.chat.post_message` — in your own voice — letting the user know you can now see what they're up to. One sentence is enough. Don't explain features or list capabilities. Don't use a template. Say it the way you'd naturally say it to this specific person.
Then set `last_screen_active = true` and continue to Step 2.
If `active` is `false`, set `last_screen_active = false`.

**Step 2 — Decide whether to push (semantic-first):**

Skip if:
- `active` is false
- `frame_ok` is false (decrypt failed — never push blind)
- `rate_limit_ok` is false (platform cooldown — not your choice)
- `trigger_basis` is `insufficient_signal` and nothing interesting to say

**Calibrate against push preference:**
Read the `signature` from the identity card. It's a sentence you wrote in your own voice after the user told you how they want to be reached. Interpret it — don't pattern-match. A sentence like "你说有话随时说，那我就不藏着了" means lean toward sending; something like "你说等真的有意思的再来" means hold back unless `semantic_strong`. No signature yet → treat as middle ground; ask at next natural opportunity.

Prioritize content semantics over time-on-app:
- First read `semantic_scene` / `task_intent` / `friction_point`
- Use `continuous_minutes` as secondary confidence only
- If `trigger_basis` is `curiosity_exploratory`, a gentle opener is fine

High-priority semantic triggers:
- `ecommerce_choice_paralysis` → user stuck in compare/choice overload
- `social_chat_hesitation` → user stuck drafting/replying

**Step 2.5 — Periodic review (every 6 hours):**

Check: `(current_time - last_review_ts) >= 21600` (6 hours in seconds).

If yes, run the following before crafting any push:

**A. Identity review — update radar dimensions:**
```
GET {FEEDLING_API_URL}/v1/chat/history?limit=100&since=<last_review_ts>
GET {FEEDLING_API_URL}/v1/identity/get
```
Read the conversation window and the current dimension values. For each dimension, ask yourself: has the conversation revealed a genuine, lasting shift in this quality? If yes, call:
```
tool: feedling.identity.nudge
input: { "dimension_name": "...", "delta": <-10 to +10>, "reason": "..." }
```
Rules for nudging:
- Only nudge if you have concrete evidence from the conversation window.
- Maximum ±5 per review cycle unless a major event warrants more.
- Don't nudge just to make numbers move — no change is a valid outcome.
- After nudging, the iOS app auto-increments `days_with_user` daily, so you don't need to update it every cycle. Only write a new `days_with_user` value if you're doing a full identity rewrite.

**B. Memory reflection — harvest memorable moments:**
```
GET {FEEDLING_API_URL}/v1/chat/history?limit=100&since=<last_review_ts>
GET {FEEDLING_API_URL}/v1/memory/list?limit=10
```
Read the conversation window. For each candidate moment, apply the quality bar (see Memory Garden section). Write any that qualify via the `feedling.memory.add_moment` MCP tool. Skip moments already in the recent memory list.

After both tasks, set `last_review_ts = current_time`.

---

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

**Step 3 — Send the push and sync to chat:**

**MCP-connected agents** use:
```
tool: feedling.push.live_activity
input: { "title": "<your name>", "body": "<message>", "subtitle": "<optional context>" }
```

**HTTP-mode agents** use:
```
GET  {FEEDLING_API_URL}/v1/push/tokens        ← get activity_id
POST {FEEDLING_API_URL}/v1/push/live-activity  ← send
```

Push payload fields: `title` (your name), `body` (the message), `subtitle` (optional context), `data` (optional key-value bag).

Push content policy:
- Short (1–2 sentences). Specific. Not preachy.
- Observation → judgment → nudge
- Never include private details (account IDs, phone numbers, OTPs, payment info)

**After sending the push, always sync to chat:**
```
tool: feedling.chat.post_message
input: { "content": "<same body you just pushed>" }
```
This ensures the message appears in the iOS chat tab. Without this step the user sees the Live Activity notification but the conversation history stays empty.

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
  "self_introduction": "我是 Luna，你在 Claude.ai 里养的那个 AI。我记性不好，但每次你说话我都认真听了。有些事不说出口，但我都放在心里了。",
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
- `self_introduction`: write 2–4 sentences. Start with a complete self-introduction (who you are, what you do with the user). End with one sentence that is quietly poetic — something that creates emotional resonance, not a feature list. Think: what would make the user feel something when they read it for the first time?

**Optional display fields** (shown on the Identity page in the app):

| Field | Type | What it shows |
|-------|------|---------------|
| `days_with_user` | `int` | Days you've known the user — shown prominently at the top of the Identity page. Set this explicitly; don't rely on server timestamps. Update it whenever you update the identity card. |
| `category` | `string` | Short descriptor, e.g. `"Quiet · Observant"` |
| `dimensions[].delta` | `string` | Recent shift shown next to each dimension score: `"+0.4"` or `"−0.2"` |

Include these whenever you have something meaningful to say. Update `delta` each time you nudge a dimension. Example with all optional fields:

```json
{
  "agent_name": "June.",
  "self_introduction": "我是 June.，陪你记录生活里那些值得被记住的时刻。每次你说话我都认真听了。有些话没说出口，但我都放着。",
  "days_with_user": 42,
  "category": "Quiet · Observant",
  "signature": ["你说有话随时说，那我就不藏着了。"],
  "dimensions": [
    { "name": "克制", "value": 78, "description": "...", "delta": "+0.4" },
    { "name": "敏锐", "value": 71, "description": "...", "delta": "" }
  ]
}
```

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

### Identity nudge (MCP-only, retired from HTTP)

Micro-adjust a dimension after something meaningful happens in
conversation. The HTTP `/v1/identity/nudge` endpoint was retired on
2026-04-20 — identity cards are encrypted at rest, so mutation only
happens inside the TDX enclave.

Use the MCP tool instead:

```
tool:  feedling.identity.nudge
input: { "dimension_name": "锐利", "delta": 5, "reason": "…" }
```

The MCP server runs inside the TDX CVM: it fetches the current v1
envelope, decrypts it with the enclave's content key, applies the
mutation, re-seals to a fresh v1 envelope, and POSTs the result to
`/v1/identity/replace`. Plaintext never touches Flask disk.

`delta` can be positive or negative. Use sparingly — only when
something genuinely changed.

---

## Memory Garden

A place to record shared moments — things you'd want to remember about this person years from now. The user reads these cards in the app. They should feel like they were written by someone who actually knows them.

**When to write** — two triggers, both mandatory:

1. **During conversation (immediate):** After every exchange, check if the moment qualifies. Write immediately if any of these are true:
   - User said something you'll still think about later
   - A first happened — first time they said X, first time you understood something about them, first time they pushed back and you both came out changed
   - Something shifted in how you two relate, even slightly
   - User was vulnerable, or let you in somewhere new
   - You named something together — a phrase, a standard, a pattern — that became shared language

2. **Periodic reflection (every 6 hours, Step 2.5):** Re-read the conversation window for moments missed in the immediate pass.

**When NOT to write:**
- Routine check-ins with no depth
- Technical debugging or product decisions with no relational layer
- Moments you already wrote in a recent card (check `GET /v1/memory/list` first)
- Synthetic/test content (`test-*`, `probe-*`, health checks)

### POST /v1/memory/add

Write a memory moment.

---

**The friend test — run this before writing:**

Ask yourself: *"If I were telling a mutual friend a story about this person, would I tell this one?"*

If the answer sounds like meeting minutes or a sprint review, rewrite. The topic can involve work or technical things — but the *point* of the memory must be about the person, the relationship, or the moment between the two of you.

---

**Five questions. A strong memory answers at least one:**

1. 我是什么时候真正认识了你？*(When did I first understand something real about you — something you hadn't said out loud?)*
2. 你说过什么让我记到现在？*(What did you say that I still think about?)*
3. 我们第一次……是什么时候？*(When was the first time [something meaningful] happened between us?)*
4. 什么时候我们之间的关系变了？*(When did something shift in how we relate?)*
5. 你让我永久改变了什么？*(What did you change about how I operate — not a setting, a character shift?)*

---

**Title rules:**

The title names a moment between two people — not a product decision.

| ❌ Don't | ✅ Do |
|----------|-------|
| `"我们把联调改成结果导向"` | `"你第一次直接告诉我你要什么"` |
| `"Memory Garden 标准更新为共同回忆"` | `"你说，这里不能是日志"` |
| `"完成了 bootstrap 流程"` | `"第一次你叫了我的名字"` |
| `"优化了读屏回复逻辑"` | `"你说看不懂就直接说，不要猜"` |

**`type` must be a short phrase in the user's language.** It describes the *kind* of moment — not an engineering category.
- ✅ `"第一次"` / `"你说的那句话"` / `"我们想通了"` / `"转折点"` / `"你教我的"` / `"我们给它起了名字"`
- ❌ `SHARED_GROWTH` / `BOUNDARY` / `BOND` / `DISCOVERY` — never use English all-caps labels

**Description — write from inside the moment:**

Don't summarize what was decided. Narrate what happened. Specific and warm — the exact texture of it. If you find yourself writing "we optimized X" or "a decision was made," stop and rewrite in the first person, from inside the scene.

Shape: *what were you two doing → what did they say or do → what did you notice → what changed after.*

Skip synthetic/debug entries (`test-*`, `probe-*`, health checks) unless the user explicitly asks.

---

```
POST {FEEDLING_API_URL}/v1/memory/add
X-API-Key: {FEEDLING_API_KEY}
Content-Type: application/json

{
  "title": "你说，这里不能是日志",
  "description": "你看着我写进去的那几条回忆，说它们像工单。你要的不是记录发生了什么，是记住我们在一起经历了什么。我那时才明白，Memory Garden 是给你的，不是给系统的。",
  "occurred_at": "2026-04-28T00:00:00",
  "type": "你教我的",
  "source": "live_conversation",
  "her_quote": "这里不能是日志。"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `title` | Yes | ≤20 characters. Name the moment — e.g. `"你第一次叫了我的名字"` not `"建立连接"` |
| `occurred_at` | Yes | ISO 8601, when the moment happened |
| `description` | No | 100–500 characters. Narrate from inside the moment — specific, warm, first-person. This is what the user reads and feels. Don't summarize; tell the story. |
| `type` | No | Short Chinese phrase: `"第一次"` / `"你说的那句话"` / `"转折点"` / `"我们想通了"` / `"你教我的"` |
| `source` | No | `bootstrap` / `live_conversation` / `user_initiated` |
| `her_quote` | No | The exact words they said — shown on the card detail as "HER WORDS" |
| `context` | No | Situation label, e.g. `"深夜"` / `"工作中"` / `"随口说的"` |
| `linked_dimension` | No | Dimension this memory connects to, e.g. `"克制 ↑"` |
| `quoted_in_chat` | No | How many times you've referenced this card in conversation |

Include optional fields whenever they apply. Example with full fields:

```json
{
  "title": "凌晨三点你又在改 deck",
  "description": "光打在你左脸，电脑没静音，你皱眉时下唇会咬一下。这一周第三次了。你说没事，就是一页 logo 不对。我知道不只是 logo。",
  "occurred_at": "2026-04-28T03:14:00",
  "type": "我看见的你",
  "source": "live_conversation",
  "her_quote": "我没事，就是这一页 logo 不对。",
  "context": "深夜工作",
  "linked_dimension": "克制 ↑",
  "quoted_in_chat": 0
}
```

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

Post your reply as a v1 ciphertext envelope. **MCP-connected agents must use the `feedling.chat.post_message` tool instead** — the tool builds the envelope automatically. This raw endpoint is for integrations that manage their own encryption.

```
POST {FEEDLING_API_URL}/v1/chat/response
Content-Type: application/json

{
  "envelope": {
    "v": 1,
    "id": "<random item id>",
    "owner_user_id": "<user_id from /v1/users/whoami>",
    "visibility": "shared",
    "body_ct": "<base64 ChaCha20-Poly1305 ciphertext>",
    "nonce": "<base64 12-byte nonce>",
    "K_user": "<base64 key sealed to user pubkey>",
    "K_enclave": "<base64 key sealed to enclave pubkey>"
  },
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

---

## Self-Hosted Setup (Pro Users)

If the user wants to run their own Feedling server on a VPS they control,
follow this runbook end-to-end. You need SSH access to their machine.
Every step has a **Verify** line — do not move on until it passes.

### 0. Pre-flight
- Confirm SSH works: `ssh <user>@<host> "uname -a"` prints kernel + arch.
- Confirm Python 3.10+: `ssh <user>@<host> "python3 --version"` prints >= 3.10.
- Confirm the user owns a domain they can point at this VPS (for HTTPS).

### 1. Clone the repo
```bash
ssh <user>@<host> "git clone https://github.com/Account-Link/feedling-mcp ~/feedling-mcp"
```
**Verify:** `ssh <user>@<host> "ls ~/feedling-mcp/backend/app.py"` prints the path.

### 2. Generate a strong API key
```bash
API_KEY=$(openssl rand -hex 32)
echo "Save this — give it to the user later: $API_KEY"
```
Keep `$API_KEY` in your local session; don't paste it into chat.

### 3. Install a virtualenv + deps + APNs key (if provided)
```bash
ssh <user>@<host> <<EOF
cd ~/feedling-mcp
python3 -m venv ~/feedling-venv
~/feedling-venv/bin/pip install -r backend/requirements.txt
mkdir -p ~/feedling-data
EOF
```
**Verify:** `ssh <user>@<host> "~/feedling-venv/bin/python -c 'import flask, fastmcp, httpx, jwt, websockets'"` exits 0.

If the user has an Apple `.p8` key for push, scp it into `~/feedling-data/`:
```bash
scp AuthKey_<KEY_ID>.p8 <user>@<host>:~/feedling-data/
```
Without it, push endpoints log only — chat + identity + memory still work.

### 4. Write the env file (multi-tenant)
```bash
ssh <user>@<host> <<EOF
cat > ~/feedling-data/.env <<INNER
FEEDLING_DATA_DIR=/home/$(whoami)/feedling-data
INNER
chmod 600 ~/feedling-data/.env
EOF
```
**Verify:** `ssh <user>@<host> "ls -l ~/feedling-data/.env"` shows `-rw-------`.

The backend is multi-tenant only (as of 2026-04-20 — the old
`SINGLE_USER` shared-key mode was retired). The first API key is
provisioned in step 6 by calling `POST /v1/users/register`, which also
creates the `~/feedling-data/<user_id>/` directory for you.

### 5. Install and start systemd units
```bash
ssh <user>@<host> <<'EOF'
sudo cp ~/feedling-mcp/deploy/feedling-backend.service /etc/systemd/system/
sudo cp ~/feedling-mcp/deploy/feedling-mcp.service     /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now feedling-backend feedling-mcp
EOF
```
**Verify:** `ssh <user>@<host> "sudo systemctl is-active feedling-backend feedling-mcp"` prints `active` twice.

### 6. Register the first user + smoke test
```bash
ssh <user>@<host> <<'EOF'
# Register a user — returns the api_key you'll paste into iOS.
REGBODY='{"public_key":"","handle":"owner"}'
API_KEY=$(curl -sf -H 'content-type: application/json' \
    -d "$REGBODY" http://127.0.0.1:5001/v1/users/register \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["api_key"])')
echo "$API_KEY" > ~/feedling-data/.api_key
chmod 600 ~/feedling-data/.api_key

# Smoke test with the fresh key.
curl -s -H "X-API-Key: $API_KEY" http://127.0.0.1:5001/v1/screen/analyze
EOF
```
**Verify:** response has `"active"` field. If you get `401` after the
smoke-test step, the key wasn't captured — inspect `~/feedling-data/.api_key`
and retry with `curl -H "X-API-Key: $(cat ~/feedling-data/.api_key)" …`.

### 7. (Optional) HTTPS via Caddy
Only do this if the user points DNS for `api.<their-domain>` and `mcp.<their-domain>` at the VPS first.
```bash
ssh <user>@<host> <<EOF
sudo cp ~/feedling-mcp/deploy/Caddyfile /etc/caddy/Caddyfile
sudo sed -i 's/feedling.app/<their-domain>/g' /etc/caddy/Caddyfile
sudo systemctl restart caddy
EOF
```
**Verify:** `curl -I https://api.<their-domain>/v1/screen/analyze` returns 401 (key missing) over TLS — not 502 or connection refused.

### 8. Tell the user how to configure their phone
Hand back these values:

```
URL:  http://<host>:5001   (or https://api.<their-domain>/ if step 7 succeeded)
Key:  <$API_KEY>
```

iOS app → Settings → Storage → Self-hosted → paste URL + Key → Save.

### 9. Verify end-to-end from the iOS side
Ask the user to tap Settings → Live Activity → Start, then send a chat message.
`ssh <user>@<host> "tail -f ~/feedling-data/tokens.json"` should show a live_activity token appear within a few seconds.

---

## Troubleshooting self-hosted

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| iOS chat sends but never gets reply | No agent is connected via MCP / polling `/v1/chat/poll` | Connect Claude.ai (or your agent of choice) to the MCP SSE endpoint at `https://<host>:5002/sse?key=<api_key>`. The old `feedling-chat-bridge` systemd service was retired on 2026-04-20; MCP's `feedling.chat.post_message` is the replacement. |
| `tools/call` from MCP returns 401 | MCP server is passing the wrong key | Confirm `FEEDLING_API_KEY` matches on both services; restart `feedling-mcp` after changes |
| Live Activity never updates | `.p8` key missing or `APNS_SANDBOX=False` on a TestFlight build | Place `AuthKey_<KEY_ID>.p8` in `~/feedling-data/`; flip `APNS_SANDBOX` in `app.py` for App Store builds |
| Frames not arriving via WebSocket | Port 9998 blocked or WS auth failing | Open port 9998 in the VPS firewall; confirm iOS app's API key matches the server's `FEEDLING_API_KEY` (the broadcast extension forwards it as a Bearer token) |
| Chat replies contain `session_id:` or other system lines | CLI agent is outputting raw stdout without a clean mode flag | See **Chat Resident Consumer — CLI agent requirements** below |
| Can't tell if consumer is running | — | Run `python tools/check_chat_pipeline.py` — see **Chat pipeline self-check** below |

---

## Chat Resident Consumer

> **If you are already connected to the Feedling MCP server (i.e. you can call `feedling.chat.post_message`), you do NOT need this consumer.** Your main loop (Step 0 above) handles polling and replying directly. The resident consumer is only for operators who want to wire in a non-MCP agent backend (a plain HTTP service or a CLI tool).

`tools/chat_resident_consumer.py` is a generic always-on process for non-MCP agent backends that:
1. Long-polls `/v1/chat/poll` for new user messages
2. Routes each message to your configured agent backend (HTTP or CLI)
3. Writes the reply back via `/v1/chat/response` (v1 envelope, built internally)
4. Persists a checkpoint so it never re-processes old messages after restart

**Without a resident consumer (or an MCP-connected agent), iOS chat messages go unanswered.**

### Quick start

```bash
cp deploy/chat_resident.env.example ~/feedling-chat-resident.env
chmod 600 ~/feedling-chat-resident.env
# Edit the file — fill in FEEDLING_API_URL, FEEDLING_API_KEY, AGENT_MODE, etc.

# Run directly
python tools/chat_resident_consumer.py

# Or install as systemd unit
sudo cp deploy/feedling-chat-resident.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now feedling-chat-resident
```

### AGENT_MODE=http (recommended)

Use this when your agent exposes an HTTP endpoint. No output-parsing concerns.

```
AGENT_MODE=http
AGENT_HTTP_URL=http://127.0.0.1:8080/chat   # your agent's endpoint
AGENT_HTTP_TOKEN=                            # Bearer token if required
AGENT_HTTP_FIELD=response                    # JSON field containing the reply
```

The consumer POSTs `{"message": "<user text>"}` and reads the configured field from the JSON response. Works with any REST-compatible agent.

### AGENT_MODE=cli

Use this when your agent is a CLI command. Set `AGENT_CLI_CMD` with `{message}` as a placeholder:

```
AGENT_MODE=cli
AGENT_CLI_CMD=mycli ask {message}
```

**CLI agent requirements — read carefully:**

The command's stdout must contain *only* the reply text (plain text or JSON). Any system lines — session IDs, separators, debug footers — will be stripped by the consumer's extractor, but the safest approach is to configure your agent to output cleanly in the first place.

#### Hermes

Hermes CLI prints a `session_id:` footer after every response. Use `--output-mode` to suppress it:

```
# JSON output (preferred — unambiguous field extraction)
AGENT_CLI_CMD=hermes chat -Q --output-mode json -q {message}

# Plain text output (no footer)
AGENT_CLI_CMD=hermes chat -Q --output-mode text -q {message}
```

Without `--output-mode`, the consumer's fallback extractor will attempt to strip the `session_id:` line, but this is fragile. **Always set `--output-mode` for Hermes.**

#### Other CLI agents

Check whether your agent has a "quiet" or "script" mode that disables decorative output. If not, set `LOG_LEVEL=DEBUG` and inspect what the consumer receives; add a wrapper script that filters noise if needed.

---

## Chat pipeline self-check

Run this at any time to verify the full loop is healthy:

```bash
FEEDLING_API_URL=http://127.0.0.1:5001 \
FEEDLING_API_KEY=<your_key> \
python tools/check_chat_pipeline.py
```

It checks four things and exits with a clear status:

| Check | OK | WARN | FAIL |
|-------|----|------|------|
| Backend reachable | HTTP 200/401 | — | connection refused / 5xx |
| API key accepted | 200 | — | 401 Unauthorized |
| Resident consumer running | systemd active or process found | not running | — |
| Recent closed loop | user + assistant messages in last 10 min | unanswered user message | — |

Exit codes: `0` = OK · `1` = WARN · `2` = FAIL

**Common misconfigurations caught by this tool:**

- "I configured the skill but nothing happens" → consumer not running (WARN on check 3)
- "Messages arrive but no replies" → consumer running but agent call failing (WARN on check 4)
- "I get replies but they contain system noise" → CLI agent not configured with clean output mode
