# feedling-mcp-v1

Feedling Skill for OpenClaw + mock backend + iOS test app.

## What this is

Feedling is a screen-awareness layer for AI companions. It captures what users do on their phone (iOS PIP screen recording) and computer (Mac screen monitoring), processes the raw data into structured insights, and exposes them via API.

This repo builds:
1. **A Feedling Skill** for OpenClaw — teaches OpenClaw how to read screen data and push to iOS
2. **A mock backend** — serves realistic screen usage data and accepts push commands
3. **An iOS test app** — minimal app to verify Dynamic Island / Live Activity push delivery

```
feedling-mcp-v1/
├── skill/          ← SKILL.md for OpenClaw
├── backend/        ← Flask mock API server
└── testapp/        ← iOS test app (SwiftUI + ActivityKit)
```

---

## Status (as of 2026-04-11)

- [x] SKILL.md written and loaded into OpenClaw ✅
- [x] Mock backend running on VPS (port 5001) ✅
- [x] OpenClaw reads Feedling skill and answers "what did I do on my phone today" ✅
- [ ] iOS testapp: Xcode project generated, needs Xcode installed + signing configured
- [ ] Real APNs push to Dynamic Island (needs Apple Developer cert setup)
- [ ] PIP screen capture → real data flowing to backend

---

## 1. Skill (`skill/SKILL.md`)

An OpenClaw skill file that declares `FEEDLING_API_URL` and `FEEDLING_API_KEY` env vars and documents all 7 API endpoints with request/response examples.

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

A Flask mock server that serves all 7 Feedling API endpoints with realistic hardcoded data.

### Run locally
```bash
cd backend
pip3 install flask
python3 app.py
# → http://localhost:5001
```

### Run on VPS
```bash
mkdir -p ~/feedling/venv
python3 -m venv ~/feedling/venv
~/feedling/venv/bin/pip install flask
nohup ~/feedling/venv/bin/python ~/feedling/app.py > ~/feedling/server.log 2>&1 &
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/screen/ios` | iPhone app usage (TikTok 45m, YouTube 35m, …) |
| GET | `/v1/screen/mac` | Mac app usage (Chrome 120m, Figma 95m, …) |
| GET | `/v1/screen/summary` | Cross-device combined view (used on heartbeat) |
| GET | `/v1/sources` | Connected data sources and sync status |
| POST | `/v1/push/dynamic-island` | Push to Dynamic Island (logs payload, returns 200) |
| POST | `/v1/push/live-activity` | Start/update Live Activity (logs payload, returns 200) |
| POST | `/v1/push/notification` | Send push notification (logs payload, returns 200) |
| POST | `/v1/push/register-token` | iOS app registers APNs / Live Activity push tokens |
| GET | `/v1/push/tokens` | Debug: list all registered push tokens |

### Quick test
```bash
curl http://localhost:5001/v1/screen/summary
curl -X POST http://localhost:5001/v1/push/notification \
  -H "Content-Type: application/json" \
  -d '{"title":"45 min on TikTok","body":"That is your budget."}'
```

---

## 3. iOS Test App (`testapp/`)

Minimal SwiftUI app with a Widget Extension. No CocoaPods, no third-party dependencies.

**Purpose:** Verify the full push chain — OpenClaw calls backend → backend sends APNs → Dynamic Island updates on phone.

### Structure
```
testapp/
├── project.yml                          ← xcodegen spec
├── Shared/
│   └── ScreenActivityAttributes.swift   ← ActivityKit data model
├── FeedlingTest/
│   ├── FeedlingTestApp.swift            ← App entry + APNs registration
│   ├── ContentView.swift                ← Status UI + test controls
│   ├── LiveActivityManager.swift        ← Start/update/stop Live Activity
│   └── FeedlingTest.entitlements        ← App Groups + APNs
└── FeedlingTestWidget/
    ├── FeedlingTestWidgetBundle.swift    ← Widget bundle entry
    ├── ScreenActivityWidget.swift        ← Dynamic Island + Lock Screen UI
    └── FeedlingTestWidget.entitlements  ← App Groups
```

### Data model
```swift
struct ScreenActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var topApp: String           // "TikTok"
        var screenTimeMinutes: Int   // 45
        var message: String          // "45 min on TikTok. That's your budget."
        var updatedAt: Date
    }
    var activityId: String
}
```

### Dynamic Island layout
- **Compact leading:** 📱 icon
- **Compact trailing:** "TikTok · 45m"
- **Expanded:** app name + screen time + OpenClaw message
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
4. For each target (`FeedlingTest` and `FeedlingTestWidget`):
   - Signing & Capabilities → set your Team
   - Add App Groups capability → `group.com.feedling.mcp`
5. Plug in iPhone → Build & Run

### What the app does

- **Start Live Activity** → ActivityKit starts a Live Activity, Dynamic Island appears
- **Simulate Push Update** → calls `activity.update()` locally to test the UI
- **Token display** → shows device token, activity push token (for wiring up real APNs later)
- All tokens are also POSTed to `FEEDLING_API_URL/v1/push/register-token` automatically

### Next: real APNs

To go from "simulated update" to "real push from OpenClaw":
1. Set up APNs auth key in Apple Developer portal
2. Add APNs sending to backend (`/v1/push/live-activity` should actually send to APNs using the registered activity token)
3. OpenClaw calls `/v1/push/live-activity` → backend sends APNs → Dynamic Island updates

---

## Architecture

```
iPhone (PIP)  ──→  Feedling Backend  ←── OpenClaw reads screen data via Skill
Mac           ──→  Feedling Backend  ←── OpenClaw pushes to iOS via Skill
                         │
                         └──→ APNs ──→ Dynamic Island / Live Activity / Notifications
```

- **Feedling** = data + delivery. No opinions, no persona.
- **OpenClaw** = the brain. Decides what to say, when to push, what tone.
- **For iOS push**, OpenClaw calls Feedling's API. Feedling handles APNs delivery.
- **Privacy**: API serves structured metadata only (app names, durations). Never raw screenshots.

---

## Config reference

| Variable | Where | Value |
|----------|-------|-------|
| `FEEDLING_API_URL` | OpenClaw env | `http://localhost:5001` (VPS local) |
| `FEEDLING_API_KEY` | OpenClaw env | `mock-key` (auth not implemented yet) |
| App Group | iOS entitlements | `group.com.feedling.mcp` |
| Team ID | Xcode signing | `DC9JH5DRMY` |
| Main bundle ID | Xcode | `com.feedling.mcp` |
| Widget bundle ID | Xcode | `com.feedling.mcp.widget` |
