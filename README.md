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

## Status (as of 2026-04-18)

**Infrastructure**
- [x] Flask backend running on VPS (port 5001)
- [x] FastMCP server (`mcp_server.py`, port 5002) — 14 MCP tools
- [x] `deploy/` — Caddyfile + systemd service files + setup.sh
- [ ] HTTPS deployment (`mcp.feedling.app`, `api.feedling.app`) — pending DNS + VPS setup

**Core features (working)**
- [x] APNs push to Dynamic Island + Live Activity
- [x] iOS Broadcast Extension → WebSocket → VPS frame storage → OCR
- [x] `/v1/screen/analyze` — semantic-first trigger, `rate_limit_ok`, `trigger_basis`
- [x] Chat long-poll (`/v1/chat/poll`) — real-time user ↔ Agent conversation
- [x] Tap Dynamic Island → opens Chat tab

**New in this version**
- [x] Identity Card — Agent writes 5-dimension personality card (`/v1/identity/*`)
- [x] Memory Garden — Agent plants memorable moments (`/v1/memory/*`)
- [x] Bootstrap — first-connection aha moment trigger (`/v1/bootstrap`)
- [x] iOS: 4-tab structure (Chat | Identity | Garden | Settings)
- [x] iOS: Identity tab with pentagon radar chart
- [x] iOS: Memory Garden tab with card list + new-card highlight
- [x] iOS: Auto-navigate to Identity tab when bootstrap completes
- [x] Push payload generalized (title / subtitle / body / data — no longer hardcoded to screen-time)
- [x] `should_notify` → `rate_limit_ok` (platform-only flag; Agent decides whether to push)
- [x] Bootstrap observability log (`bootstrap_events.jsonl`)

**Pending**
- [ ] HTTPS + DNS
- [ ] Multi-tenant (user_id per device)
- [ ] Claude.ai connector end-to-end test
- [ ] Onboarding docs

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
| Chat bridge | `backend/chat_bridge.py` | — | Hermes auto-reply (opt-in only) |

### Run (quick start)

```bash
cd backend
pip install -r requirements.txt
nohup python app.py > ~/app.log 2>&1 &
nohup python mcp_server.py > ~/mcp.log 2>&1 &
```

For production, use the systemd services in `deploy/`.

### HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/bootstrap` | First-connection trigger — returns instructions for Agent |
| GET | `/v1/identity/get` | Read identity card |
| POST | `/v1/identity/init` | Write identity card (once, 5 dimensions) |
| POST | `/v1/identity/nudge` | Micro-adjust one dimension (delta + reason) |
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
| `feedling.identity.nudge` | POST /v1/identity/nudge |
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

---

## OpenClaw setup (HTTP mode)

```bash
# Install skill
mkdir -p ~/.openclaw/skills/feedling
cp skill/SKILL.md ~/.openclaw/skills/feedling/SKILL.md

# Set env vars in ~/.openclaw/openclaw.json
{
  "skills": {
    "entries": {
      "feedling": {
        "env": {
          "FEEDLING_API_URL": "http://localhost:5001",
          "FEEDLING_API_KEY": "mock-key"
        }
      }
    }
  }
}
```

---

## Config reference

| Variable | Value |
|----------|-------|
| `FEEDLING_API_URL` | `http://localhost:5001` (VPS local) |
| `FEEDLING_API_KEY` | `mock-key` (change for production) |
| Flask port | `5001` |
| MCP port | `5002` |
| WebSocket port | `9998` |
| App Group | `group.com.feedling.mcp` |
| Team ID | `DC9JH5DRMY` |
| Main bundle ID | `com.feedling.mcp` |
| APNs Key ID | `5TH55X5U7T` |
| APNs .p8 path | `~/feedling/AuthKey_5TH55X5U7T.p8` |
| Data dir | `~/feedling-data/` |
