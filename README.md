# feedling-mcp-v1

Feedling Skill for OpenClaw + backend + iOS test app with screen recording.

## What this is

Feedling is a screen-awareness layer for AI companions. It captures what users do on their phone (iOS Broadcast Extension screen recording) and computer (Mac screen monitoring), processes the raw data into structured insights, and exposes them via API.

This repo builds:
1. **A Feedling Skill** for OpenClaw — teaches OpenClaw how to read screen data and push to iOS
2. **A backend** — serves screen usage data, accepts push commands, receives WebSocket frames from phone
3. **An iOS test app** — app with Broadcast Extension for screen capture + Dynamic Island / Live Activity push delivery

```
feedling-mcp-v1/
├── skill/          ← SKILL.md for OpenClaw
├── backend/        ← Flask API server + WebSocket ingest
└── testapp/        ← iOS app (SwiftUI + ActivityKit + ReplayKit Broadcast Extension)
```

---

## Status (as of 2026-04-15)

- [x] SKILL.md written and loaded into OpenClaw ✅
- [x] Backend running on VPS (HTTP port 5001, WebSocket port 9998) ✅
- [x] OpenClaw reads Feedling skill and answers "what did I do on my phone today" ✅
- [x] iOS testapp: Build & Run to real device ✅
- [x] Real APNs push to Dynamic Island (JWT + `.p8` key) ✅
- [x] OpenClaw self-drives full push chain: query token → Feedling API → APNs → Dynamic Island ✅
- [x] Dynamic Island expanded view with OpenClaw message (up to 5 lines) ✅
- [x] iOS Broadcast Extension captures screen every 1s → WebSocket → VPS storage ✅
- [x] Vision OCR on captured frames — real app names visible in metadata ✅
- [x] `/v1/screen/frames/latest` endpoint — OpenClaw can see what user is doing on phone ✅
- [x] `/v1/screen/analyze` heartbeat endpoint — push cooldown, jitter-tolerant continuous time, OCR dedup ✅
- [x] Push cooldown: thread-safe + persisted to `push_state.json` (survives restarts) ✅
- [x] **Chat window in iOS app** — user ↔ OpenClaw real-time conversation ✅
- [x] **Live Activity pushes mirror to Chat** — full conversation context in one place ✅
- [x] **Long-poll endpoint** `/v1/chat/poll` — OpenClaw notified instantly when user sends message ✅
- [x] **Tap Dynamic Island → opens Chat tab** directly ✅
- [ ] OpenClaw long-poll loop validated end-to-end
- [ ] Replace mock `/v1/screen/ios` with real frame aggregation
- [ ] Mac screen monitoring data → real upload to backend

---

## 1. Skill (`skill/SKILL.md`)

An OpenClaw skill file that declares `FEEDLING_API_URL` and `FEEDLING_API_KEY` env vars and documents all API endpoints with request/response examples.

**Install on OpenClaw VPS:**
```bash
mkdir -p ~/.openclaw/skills/feedling
cp skill/SKILL.md ~/.openclaw/skills/feedling/SKILL.md
```

**Configure env vars** in `~/.openclaw/openclaw.json`:
```json
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

The env vars also need to be in the systemd unit (since OpenClaw runs as a service):
```bash
mkdir -p ~/.config/systemd/user/openclaw-gateway.service.d
cat > ~/.config/systemd/user/openclaw-gateway.service.d/feedling.conf <<EOF
[Service]
Environment=FEEDLING_API_URL=http://localhost:5001
Environment=FEEDLING_API_KEY=mock-key
EOF
systemctl --user daemon-reload && systemctl --user restart openclaw-gateway
```

---

## 2. Backend (`backend/app.py`)

Flask server with HTTP API + WebSocket ingest. Handles APNs push with JWT auth.

### Run on VPS
```bash
mkdir -p ~/feedling/venv
python3 -m venv ~/feedling/venv
~/feedling/venv/bin/pip install flask websockets PyJWT cryptography 'httpx[http2]'
nohup ~/feedling/venv/bin/python ~/feedling/app.py > ~/feedling/server.log 2>&1 &
```

### HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/screen/ios` | iPhone app usage (mock or aggregated from frames) |
| GET | `/v1/screen/mac` | Mac app usage |
| GET | `/v1/screen/summary` | Cross-device combined view |
| GET | `/v1/sources` | Connected data sources and sync status |
| POST | `/v1/push/dynamic-island` | Push to Dynamic Island |
| POST | `/v1/push/live-activity` | Start/update Live Activity via APNs |
| POST | `/v1/push/notification` | Send push notification |
| POST | `/v1/push/register-token` | iOS app registers APNs / Live Activity tokens |
| GET | `/v1/push/tokens` | List all registered push tokens |
| GET | `/v1/screen/frames` | List captured screen frames with OCR metadata |
| GET | `/v1/screen/frames/latest` | Latest frame: base64 JPEG + OCR text + URLs |
| GET | `/v1/screen/frames/<filename>` | Retrieve specific frame |
| GET | `/v1/screen/analyze` | Heartbeat: semantic-first trigger signals (`semantic_scene/task_intent/friction_point`), suggested openers, and `should_notify` (with cooldown) |
| GET | `/v1/chat/history` | Fetch chat history (`limit`, `since` params) |
| POST | `/v1/chat/message` | User sends a message (called by iOS app) |
| POST | `/v1/chat/response` | OpenClaw posts a reply (optionally triggers Live Activity push) |
| GET | `/v1/chat/poll` | Long-poll: blocks until user message arrives or timeout (`since`, `timeout` params) |

### WebSocket Ingest

The phone connects to `ws://<VPS>:9998/ingest` and streams frames as JSON:

```json
{
  "type": "frame",
  "ts": 1744459200.0,
  "app": "TikTok",
  "bundle": "com.zhiliaoapp.musically",
  "ocr_text": "For You\nFollowing\n...",
  "urls": [],
  "image": "<base64 JPEG>",
  "w": 960,
  "h": 2079,
  "tier_hint": 1,
  "routing_signals": {
    "dhash_distance": 8,
    "ocr_text_length": 120,
    "ocr_url_count": 0,
    "bundle_id": "com.zhiliaoapp.musically",
    "is_text_heavy_app": false
  }
}
```

---

## 3. iOS Test App (`testapp/`)

SwiftUI app with Widget Extension and Broadcast Upload Extension. No CocoaPods, no third-party dependencies.

### Structure
```
testapp/
├── project.yml                              ← xcodegen spec (4 targets)
├── Shared/
│   └── ScreenActivityAttributes.swift       ← ActivityKit data model
├── FeedlingTest/
│   ├── FeedlingTestApp.swift                ← App entry + APNs + URL scheme handler
│   ├── ContentView.swift                    ← TabView root (Chat + Settings) + AppRouter
│   ├── FeedlingAPI.swift                    ← Base URL config (env var or default)
│   ├── ChatMessage.swift                    ← Chat message model (role/content/ts/source)
│   ├── ChatViewModel.swift                  ← Chat state: polling, send, optimistic insert
│   ├── ChatView.swift                       ← Chat UI: bubbles, typing indicator, input bar
│   ├── LiveActivityManager.swift            ← Start/update/stop Live Activity
│   └── FeedlingTest.entitlements            ← App Groups + APNs
├── FeedlingBroadcast/                       ← Broadcast Upload Extension
│   ├── SampleHandler.swift                  ← RPBroadcastSampleHandler (3s capture interval)
│   ├── SampleHandler+WebSocketQueue.swift   ← Vision OCR + WebSocket frame queue
│   ├── WebSocketManager.swift               ← URLSessionWebSocketTask, auto-reconnect
│   ├── SharedConfig.swift                   ← App Group ID, capture interval config
│   └── Info.plist
├── FeedlingBroadcastSetupUI/                ← Broadcast Setup UI Extension (required by iOS)
│   ├── BroadcastSetupViewController.swift
│   └── Info.plist
└── FeedlingTestWidget/
    ├── FeedlingTestWidgetBundle.swift        ← Widget bundle entry
    ├── ScreenActivityWidget.swift            ← Dynamic Island + Lock Screen UI
    └── FeedlingTestWidget.entitlements       ← App Groups
```

### Data model
```swift
struct ScreenActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var topApp: String           // "TikTok"
        var screenTimeMinutes: Int   // 45
        var message: String          // "45 min on TikTok. That's your budget."
        var updatedAt: Date          // Unix timestamp from backend
    }
    var activityId: String
}
```

### Dynamic Island layout
- **Compact leading:** ✦ OpenClaw
- **Compact trailing:** first 18 chars of message
- **Expanded bottom:** full message (up to 5 lines) + app name + time
- **Lock screen:** same info, dark background

### Setup (first time)

1. Install Xcode from App Store
2. Generate Xcode project:
   ```bash
   cd testapp
   brew install xcodegen  # if not installed
   xcodegen generate
   ```
3. Open `FeedlingTest.xcodeproj`
4. For each target — sign with your team, verify App Groups = `group.com.feedling.mcp`
5. Plug in iPhone (iOS 16.2+) → Build & Run

### Screen recording (phone → VPS)

1. Open the app → tap **Start Screen Recording**
2. System picker appears → select **FeedlingTest** → tap **Start Broadcast**
3. The `FeedlingBroadcast` extension starts capturing:
   - Every 1 second: grab video frame → resize to 960px → JPEG @ 0.6 quality
   - Vision OCR: extract text + URLs from frame
   - WebSocket: send JSON payload to `ws://54.209.126.4:9998/ingest`
4. Backend stores frames in `~/feedling/frames/<session_id>/`
5. OpenClaw can call `/v1/screen/frames/latest` to see what the user is currently doing

---

## Architecture

```
iPhone (Broadcast Extension)
  ↓ WebSocket (port 9998)
Feedling Backend (VPS)  ←── OpenClaw long-polls /v1/chat/poll (real-time chat)
  ↓                     ←── OpenClaw reads /v1/screen/analyze (every ~30s)
  ↓ APNs (JWT + .p8)
Dynamic Island / Live Activity
  ↑
OpenClaw: POST /v1/chat/response (chat reply, optionally also pushes to Dynamic Island)
          POST /v1/push/live-activity (proactive push, auto-mirrored to Chat)

iOS App (Chat Tab)
  ↑ 2s polling /v1/chat/history
  → tap Dynamic Island → opens Chat tab directly (feedlingtest:// URL scheme)
```

- **Feedling** = data capture + delivery pipeline. No opinions, no persona.
- **OpenClaw** = the brain. Decides what to say, when to push, what tone.
- **Screen data flow**: phone records → WebSocket → VPS stores → OpenClaw reads via API
- **Chat flow**: user types → `POST /v1/chat/message` → wakes long-poll → OpenClaw responds → iOS polls → shows in Chat
- **Proactive flow**: OpenClaw sees something → pushes Live Activity → auto-saved to Chat → user sees both on Dynamic Island and in Chat tab

---

## Config reference

| Variable | Where | Value |
|----------|-------|-------|
| `FEEDLING_API_URL` | OpenClaw env | `http://localhost:5001` (VPS local) |
| `FEEDLING_API_KEY` | OpenClaw env | `mock-key` |
| HTTP port | VPS | `5001` |
| WebSocket port | VPS | `9998` |
| SSH port | VPS | `443` (port 22 unavailable) |
| App Group | iOS entitlements | `group.com.feedling.mcp` |
| Team ID | Xcode signing | `DC9JH5DRMY` |
| Main bundle ID | Xcode | `com.feedling.mcp` |
| Broadcast bundle ID | Xcode | `com.feedling.mcp.broadcast` |
| Widget bundle ID | Xcode | `com.feedling.mcp.widget` |
| APNs Key ID | VPS | `5TH55X5U7T` |
| APNs .p8 path | VPS | `~/feedling/AuthKey_5TH55X5U7T.p8` |
| Frames storage | VPS | `~/feedling/frames/` |
