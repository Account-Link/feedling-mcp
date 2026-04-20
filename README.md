# feedling-mcp-v1

Feedling gives your Personal Agent a body on iOS — Dynamic Island, Live Activity, Chat, Identity Card, Memory Garden.

## What this is

Agent 是大脑，Feedling 是身体。

This repo provides:
1. **A FastMCP server** — exposes Feedling tools over MCP protocol (Claude.ai / Claude Desktop compatible)
2. **A Flask HTTP backend** — serves the iOS app and is called internally by the MCP server
3. **A Skill file for OpenClaw** — HTTP-mode agents read `skill/SKILL.md`
4. **An iOS app** — Chat, Identity Card, Memory Garden, Settings + Live Activity / Dynamic Island

```
feedling-mcp-v1/
├── skill/          ← SKILL.md for OpenClaw (HTTP mode)
├── backend/        ← Flask API (port 5001) + FastMCP server (port 5002)
├── deploy/         ← Caddyfile, systemd services, setup.sh
├── docs/           ← PROJECT_BRIEF.md, ROADMAP.md, CHANGELOG.md
└── testapp/        ← iOS SwiftUI app + Widget + Broadcast Extension
```

---

## Status (as of 2026-04-20)

**Infrastructure**
- [x] Flask backend on VPS (port 5001) — multi-tenant only (SINGLE_USER retired 2026-04-20)
- [x] FastMCP server (`mcp_server.py`, port 5002) — 14 MCP tools, SSE with per-key sessions
- [x] `deploy/` — Caddyfile + systemd service files + `setup.sh` that generates a fresh API key
- [x] Multi-tenant: per-user directories, `POST /v1/users/register`, bcrypt-hashed API keys
- [x] HTTPS — `api.feedling.app` and `mcp.feedling.app` on Let's Encrypt via Caddy

**Core features (working)**
- [x] APNs push to Dynamic Island + Live Activity
- [x] iOS Broadcast Extension → WebSocket (auth via `Bearer` api_key) → per-user frame storage → OCR
- [x] `/v1/screen/analyze` — semantic-first trigger, `rate_limit_ok`, `trigger_basis`
- [x] Chat long-poll (`/v1/chat/poll`) — real-time user ↔ Agent conversation, isolated per user
- [x] Tap Dynamic Island → opens Chat tab
- [x] Identity Card — Agent writes 5-dimension personality card (`/v1/identity/*`)
- [x] Memory Garden — Agent plants memorable moments (`/v1/memory/*`)
- [x] Bootstrap — first-connection aha moment trigger (`/v1/bootstrap`)
- [x] iOS: 4-tab structure (Chat | Identity | Garden | Settings)
- [x] iOS: Settings → Storage toggle (Feedling Cloud vs Self-hosted URL+key)
- [x] iOS: Settings → Agent Setup → copy-paste MCP connection string + env vars

**E2E + TDX (Phase 1–3 shipped)**
- [x] Phase 1 — dstack TDX CVM deployed on Phala Cloud; /attestation returns
      a DCAP-signed quote binding the enclave's content-pubkey + release metadata
- [x] Phase 2 — iOS audit card runs DCAP + event-log replay + `mr_config_id`
      binding + on-chain `addComposeHash` check; command-line auditor
      (`tools/audit_live_cvm.py`) mirrors the same checks
- [x] Phase 3 — **TLS terminates inside the enclave**. Self-signed ECDSA-P256
      cert is derived deterministically from dstack-KMS (bound to `compose_hash`);
      `sha256(cert.DER)` is baked into REPORT_DATA. iOS pins the live cert
      against that fingerprint on every audit — MITM is detectable, not just
      implicitly-trusted

**Pending**
- [ ] Full-repo content encryption rollout (content envelopes, key backup,
      rewrap migration — Phases 4–5 in `docs/DESIGN_E2E.md`)
- [ ] Claude.ai connector submission

---

## Architecture

```
Claude.ai / Claude Desktop       OpenClaw / Hermes
        │                               │
        │ MCP protocol (port 5002)      │ HTTP + SKILL.md (port 5001)
        ▼                               ▼
┌─────────────────────────────────────────────┐
│           Feedling Backend (VPS)            │
│  mcp_server.py (FastMCP, port 5002)         │
│      └─ calls → app.py (Flask, port 5001)   │
│                                             │
│  Identity Card  Memory Garden  Bootstrap    │
│  Push (APNs)   Screen frames   Chat         │
└─────────────────────────────────────────────┘
        │ APNs (JWT + .p8)      ▲ WebSocket (port 9998)
        ▼                       │
┌─────────────────────────────────────────────┐
│           iPhone (iOS App)                  │
│  Chat | Identity | Garden | Settings        │
│  Dynamic Island / Live Activity             │
│  Broadcast Extension (screen capture)       │
└─────────────────────────────────────────────┘
```

---

## Backend

### Processes

| Process | File | Port | Purpose |
|---------|------|------|---------|
| Flask backend | `backend/app.py` | 5001 | iOS app API, data storage |
| MCP server | `backend/mcp_server.py` | 5002 | MCP protocol for Claude.ai / agents |

(Before 2026-04-20 there was a third service, `backend/chat_bridge.py`,
that polled Flask and relayed user messages to Hermes for auto-reply.
It was retired when MCP's `feedling.chat.post_message` tool landed — the
replacement path writes replies as v1 envelopes directly inside the
enclave, so there's no plaintext stop-over.)

### Run (quick start)

**Docker / docker-compose (recommended, dstack-ready):**

```bash
cp deploy/feedling.env.example deploy/.env   # edit APNs, public base URL, etc.
docker compose -f deploy/docker-compose.yaml --env-file deploy/.env up -d --build
```

This brings up `backend` (Flask, port 5001) + `mcp` (FastMCP SSE, port 5002).
Data persists in the named volume `feedling_data` (mounted at `/data`).
Drop the APNs `.p8` into that volume to enable push.

The same `docker-compose.yaml` is the deployment unit for the future dstack
TDX deployment — see `docs/DESIGN_E2E.md`.

**Bare-metal / systemd:**

```bash
cd backend
pip install -r requirements.txt
nohup python app.py > ~/app.log 2>&1 &
nohup python mcp_server.py > ~/mcp.log 2>&1 &
```

Or use the systemd services + `deploy/setup.sh` — generates a fresh API key
and writes `~/feedling.env` automatically.

### HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/bootstrap` | First-connection trigger — returns instructions for Agent |
| GET | `/v1/identity/get` | Read identity card |
| POST | `/v1/identity/init` | Write identity card (once, 5 dimensions) |
| ~~POST~~ | ~~`/v1/identity/nudge`~~ | Removed 2026-04-20 — use MCP `feedling.identity.nudge` |
| GET | `/v1/memory/list` | List memory moments |
| GET | `/v1/memory/get` | Get one moment by id |
| POST | `/v1/memory/add` | Add a memory moment |
| DELETE | `/v1/memory/delete` | Delete a moment by id |
| GET | `/v1/screen/analyze` | Semantic-first screen analysis + `rate_limit_ok` |
| GET | `/v1/screen/frames/latest` | Latest frame: base64 + OCR |
| GET | `/v1/screen/frames` | List recent frames (metadata) |
| POST | `/v1/push/dynamic-island` | Push to Dynamic Island |
| POST | `/v1/push/live-activity` | Update Live Activity |
| GET | `/v1/push/tokens` | List registered APNs tokens |
| POST | `/v1/push/register-token` | iOS app registers token |
| GET | `/v1/chat/history` | Fetch chat history |
| POST | `/v1/chat/message` | User sends a message (iOS app) |
| POST | `/v1/chat/response` | Agent posts a reply |
| GET | `/v1/chat/poll` | Long-poll: blocks until user message |

### MCP Tools (14 total)

| Tool | Maps to |
|------|---------|
| `feedling.bootstrap` | POST /v1/bootstrap |
| `feedling.identity.init` | POST /v1/identity/init |
| `feedling.identity.get` | GET /v1/identity/get |
| `feedling.identity.nudge` | in-enclave decrypt-mutate-rewrap → POST /v1/identity/replace |
| `feedling.memory.add_moment` | POST /v1/memory/add |
| `feedling.memory.list` | GET /v1/memory/list |
| `feedling.memory.get` | GET /v1/memory/get |
| `feedling.memory.delete` | DELETE /v1/memory/delete |
| `feedling.push.dynamic_island` | POST /v1/push/dynamic-island |
| `feedling.push.live_activity` | POST /v1/push/live-activity |
| `feedling.screen.latest_frame` | GET /v1/screen/frames/latest |
| `feedling.screen.analyze` | GET /v1/screen/analyze |
| `feedling.chat.post_message` | POST /v1/chat/response |
| `feedling.chat.get_history` | GET /v1/chat/history |

---

## iOS App

### Tab structure

| Tab | Content |
|-----|---------|
| Chat | Real-time conversation with Agent |
| Identity | Agent's personality card — pentagon radar chart, 5 dimensions |
| Garden | Memory garden — cards of memorable moments |
| Settings | Screen recording, Live Activity controls, push tokens, API info |

### Setup (first time)

1. Open `testapp/FeedlingTest.xcodeproj` in Xcode
2. For each target: sign with your team, verify App Groups = `group.com.feedling.mcp`
3. Plug in iPhone (iOS 16.2+) → Build & Run

### ContentState (Live Activity / Dynamic Island)

```swift
struct ContentState: Codable, Hashable {
    var title: String           // Agent name, e.g. "Luna"
    var subtitle: String?       // Optional context, e.g. "TikTok · 45m"
    var body: String            // Main message
    var personaId: String?      // Reserved, use "default"
    var templateId: String?     // Reserved, use "default"
    var data: [String: String]  // Extension bag, e.g. ["top_app": "TikTok", "minutes": "45"]
    var updatedAt: Date
}
```

### File structure

```
testapp/
├── Shared/
│   └── ScreenActivityAttributes.swift    ← ActivityKit data model
├── FeedlingTest/
│   ├── FeedlingTestApp.swift             ← App entry + APNs
│   ├── ContentView.swift                 ← 4-tab root + AppRouter
│   ├── FeedlingAPI.swift                 ← Base URL config
│   ├── ChatView.swift / ChatViewModel.swift / ChatMessage.swift
│   ├── IdentityView.swift                ← Radar chart + dimensions list
│   ├── IdentityViewModel.swift           ← Polls /v1/identity/get every 10s
│   ├── MemoryGardenView.swift            ← Moment cards
│   ├── MemoryViewModel.swift             ← Polls /v1/memory/list every 10s
│   └── LiveActivityManager.swift
├── FeedlingBroadcast/                    ← Screen capture extension
├── FeedlingBroadcastSetupUI/
└── FeedlingTestWidget/                   ← Dynamic Island + Lock Screen widget
```

---

## Bootstrap flow (aha moment)

1. Agent calls `POST /v1/bootstrap`
2. Backend returns `first_time` + instructions
3. Agent calls `feedling.identity.init` → writes 5-dimension personality card
4. Agent searches its own memory → calls `feedling.memory.add_moment` 3-5 times
5. Agent calls `feedling.chat.post_message` → "I'm here, go check the app"
6. iOS app detects identity card appeared → auto-switches to Identity tab
7. User sees: filled radar chart + memory garden cards + chat message

### Memory Garden quality standard (shared-memory mode)

Memory Garden should feel like "our memories", not debug logs.

A moment qualifies as a good memory if it satisfies all 3:
1. It deepens mutual understanding (the agent understands the user better, or vice versa)
2. It records a meaningful crossing (we overcame friction / made progress together)
3. It leaves a lasting behavioral change (a rule, tone, boundary, or workflow we keep using)

Writing guidance:
- Use everyday human language, emotionally legible, not ticket-style wording
- Describe turning points, not generic status updates
- Prefer "what changed between us" over "what endpoint was called"
- Avoid synthetic test content (`test-*`, `probe-*`) in production gardens

Recommended card structure:
- `title`: short and warm, like a memory label
- `description`: "what happened → what the user cared about → what changed after"
- `type`: relationship-oriented tags (e.g. "共同突破" / "彼此理解" / "新约定")

---

## Agent setup

### Claude.ai / Claude Desktop (SSE MCP)

Cloud users get a one-liner from the iOS app's **Settings → Agent Setup → Copy MCP string**:

```
claude mcp add feedling --transport sse "https://mcp.feedling.app/sse?key=<api_key>"
```

Self-hosted users derive the same shape using their own domain:

```
claude mcp add feedling --transport sse "https://mcp.<your-domain>/sse?key=<api_key>"
```

The `?key=` is captured by an ASGI middleware on the first SSE GET and pinned
to the MCP session — every subsequent tool call is routed as that user.

### OpenClaw / HTTP-skill agents

```bash
mkdir -p ~/.openclaw/skills/feedling
cp skill/SKILL.md ~/.openclaw/skills/feedling/SKILL.md
```

`~/.openclaw/openclaw.json`:

```json
{
  "skills": {
    "entries": {
      "feedling": {
        "env": {
          "FEEDLING_API_URL": "https://api.feedling.app",
          "FEEDLING_API_KEY": "<your_api_key>"
        }
      }
    }
  }
}
```

Pro users (self-hosted): see `skill/SKILL.md` → **Self-Hosted Setup** for an
end-to-end SSH runbook an agent can follow to deploy the server itself.

---

## Config reference

| Variable | Value |
|----------|-------|
| `FEEDLING_API_URL` | `http://localhost:5001` (VPS local) |
| `FEEDLING_DATA_DIR` | `~/feedling-data/` |
| `FEEDLING_MCP_TRANSPORT` | `sse` (default) or `streamable-http` |
| Flask port | `5001` |
| MCP port | `5002` |
| WebSocket port | `9998` |
| App Group | `group.com.feedling.mcp` |
| Team ID | `DC9JH5DRMY` |
| Main bundle ID | `com.feedling.mcp` |
| APNs Key ID | `5TH55X5U7T` |
| APNs .p8 path | `~/feedling/AuthKey_5TH55X5U7T.p8` |
| Data dir | `~/feedling-data/` |

### Multi-tenant data layout

```
~/feedling-data/
├── users.json                  # [{user_id, api_key_hash, public_key, created_at}, …]
├── .pepper                     # 32-byte HMAC secret, chmod 600
└── <user_id>/
    ├── frames/                 # per-user screen frames
    ├── chat.json
    ├── identity.json
    ├── memory.json
    ├── tokens.json             # APNs tokens (not content — no encryption needed)
    ├── push_state.json
    ├── live_activity_state.json
    ├── bootstrap.json
    └── bootstrap_events.jsonl
```

All users live at `~/feedling-data/<user_id>/` — there is no shared-key
flat-layout mode anymore. `users.json` + `.pepper` at the top level are
the only files outside a user directory.
