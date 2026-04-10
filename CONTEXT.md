# Feedling Skill for OpenClaw — Project Context

## What is this project

Feedling is a screen-awareness layer for AI companions. It captures what users do on their phone (iOS PIP screen recording) and computer (Mac screen monitoring), processes the raw data into structured insights, and exposes them via API.

This repo builds **one thing**: a Feedling Skill for OpenClaw, plus the minimal backend API it needs.

## How it fits together

```
iOS App (PIP)  ──→  Feedling Backend API  ←── OpenClaw reads screen data via Skill
Mac App        ──→  Feedling Backend API  ←── OpenClaw pushes to iOS via Skill
```

- Feedling = the eyes + the delivery channel. It collects screen data and delivers pushes to iOS (Dynamic Island, Live Activity, notifications via APNs).
- OpenClaw = the brain and the voice. It decides what to do with the data, what to say, when to push. It controls tone, personality, and timing.
- For Telegram / Discord / Lark, OpenClaw messages users directly through its own native channel integrations — no Feedling involvement.

## What the Skill provides

### Read endpoints (screen data)

1. `GET /v1/screen/ios` — iPhone screen usage (apps, durations, categories, scroll distance)
2. `GET /v1/screen/mac` — Mac screen usage (apps, window titles, focus score, deep work time, context switches)
3. `GET /v1/screen/summary` — Cross-device combined view
4. `GET /v1/sources` — Which data sources are connected and their status

### Write endpoints (push to iOS)

5. `POST /v1/push/dynamic-island` — Push a status update to the user's Dynamic Island
6. `POST /v1/push/live-activity` — Start or update a Live Activity on the lock screen
7. `POST /v1/push/notification` — Send a push notification to the Feedling iOS app

These push endpoints are Feedling infrastructure — OpenClaw cannot directly send APNs to an iOS app, so it calls Feedling's backend to do it. OpenClaw decides WHAT to say and WHEN to push; Feedling handles the delivery.

For messaging platforms (Telegram, Discord, Lark), OpenClaw has its own native channel integrations and does not need Feedling for those.

## What needs to be built

### 1. SKILL.md
An OpenClaw skill file that:
- Declares dependency on `FEEDLING_API_URL` and `FEEDLING_API_KEY` env vars
- Documents the 4 read endpoints and 3 push endpoints with request/response examples
- Suggests heartbeat usage: check `/v1/screen/summary` periodically, OpenClaw decides what to do with the data
- Includes a note that Feedling provides a daily summary endpoint — OpenClaw can use this however it wants
- Contains NO persona definitions, NO default character — the user's OpenClaw personality is in full control of tone, style, and voice

### 2. Mock Backend API
A minimal HTTP server (Python Flask or Node Express) that:
- Serves the 4 read endpoints with hardcoded mock data
- Serves the 3 push endpoints (accept the payload, log it to console — no real APNs yet)
- Returns realistic-looking screen usage JSON
- Can run locally for testing with OpenClaw

### 3. OpenClaw local setup
- Install OpenClaw on Mac
- Add the Feedling Skill to the workspace
- Configure env vars pointing to the local mock server
- Verify that OpenClaw can read the mock screen data and do something with it

## Key design decisions

- **Feedling is data + delivery.** It collects screen data and delivers pushes to iOS via APNs. It has no opinions — no persona, no voice, no style.
- **The user's OpenClaw is in full control of content.** Whatever personality the user has configured in OpenClaw drives the tone, timing, and content of all messages. Feedling just provides the data and the push channel.
- **For iOS push (Dynamic Island, Live Activity, notifications), OpenClaw calls Feedling's API.** OpenClaw can't send APNs directly. For messaging platforms (Telegram, Discord, Lark), OpenClaw uses its own native channels — Feedling is not involved.
- **All screen data goes through the Feedling backend API.** Even Mac screen data. Because OpenClaw can run locally or on a cloud VPS, we can't assume it has direct access to local files.
- **Privacy by design.** The API serves structured metadata (app names, categories, durations), never raw screenshots or content. Raw data is processed on-device before upload.

## Existing code

There are existing codebases from our engineering team for:
- iOS PIP screen capture (currently integrated in the Feedling iOS app)
- Mac screen monitoring tool
- Live Activity / Dynamic Island components
- Backend infrastructure

These will be integrated later. For now, the mock backend is sufficient to demo the full loop.

## Immediate goal

Get a working demo: OpenClaw + Feedling Skill + mock backend, running locally on a Mac, where you can ask OpenClaw "what did I do on my phone today" and it calls the Feedling API and answers with real (mock) data.
