# Feedling — Next Build Phase

This document is the handoff spec for the next engineering session.
Read this alone and you have everything needed to continue.

---

## What Exists Today (working, deployed)

```
backend/app.py        Flask HTTP API (port 5001) — all business logic
backend/mcp_server.py FastMCP server (port 5002) — wraps Flask as MCP tools
testapp/              iOS SwiftUI app — Chat, Identity, Garden, Settings tabs
deploy/               Caddy + systemd service files + setup.sh
skill/SKILL.md        OpenClaw HTTP skill
```

**All endpoints (working on VPS at 54.209.126.4:5001):**

```
WS   /ws                           iOS streams screen frames here (with OCR text)
GET  /v1/screen/analyze            keyword-based screen state (no model call)
GET  /v1/screen/frames             list recent frames
GET  /v1/screen/frames/latest      latest frame as base64
GET  /v1/screen/frames/<file>      serve frame jpg

POST /v1/push/live-activity        push to Dynamic Island + lock screen
POST /v1/push/dynamic-island       push to Dynamic Island
POST /v1/push/live-start           push-to-start a new Live Activity
GET  /v1/push/tokens               list registered APNs tokens
POST /v1/push/register-token       iOS app registers its APNs token

GET  /v1/chat/history              fetch chat history
POST /v1/chat/message              user sends message (iOS → server)
POST /v1/chat/response             agent posts reply
GET  /v1/chat/poll                 long-poll: blocks until user message

GET  /v1/identity/get              read identity card
POST /v1/identity/init             write identity card (5 dimensions)
POST /v1/identity/nudge            adjust one dimension

GET  /v1/memory/list               list memory moments
GET  /v1/memory/get                get one moment by id
POST /v1/memory/add                add a moment
DELETE /v1/memory/delete           delete a moment

POST /v1/bootstrap                 first-connection trigger
```

**MCP tools (14):** wrap all of the above (see mcp_server.py).

**Current limitation:** single-user, all data flat in `~/feedling-data/`, one hardcoded API key (`mock-key`), no HTTPS.

---

## Target Architecture

### Two user types

**Normal user** — iPhone + Claude.ai or ChatGPT, no VPS.
- Data stored on feedling.app (we host).
- E2E encrypted: we store ciphertext only, cannot read.
- Onboarding: open app → register → copy one MCP string → paste into agent. Done.

**Pro user** — iPhone + Hermes/OpenClaw + their own VPS.
- Data stored on their VPS, we see nothing.
- Agent (on same VPS) reads files directly via SSH MCP or HTTP skill.
- Onboarding: agent deploys the server itself using SKILL.md runbook.

### The onboarding string (normal user)

```
claude mcp add feedling --transport sse \
  "https://mcp.feedling.app/sse?key=<api_key>"
```

One string. The `key` query param authenticates the request and routes to the user's data. Works with Claude Desktop, Claude Code, any SSE MCP client.

For OpenClaw/HTTP skill users, same key used as header:
```
FEEDLING_API_URL=https://api.feedling.app
FEEDLING_API_KEY=<api_key>
```

### Encryption model

```
At registration (on iOS device):
  CryptoKit generates keypair (Curve25519 or P-256)
  public key  → uploaded to feedling.app
              → server encrypts all stored data with this key
  private key → iOS Secure Enclave (Keychain)
              → user copies to agent once during setup

We store:   public key + api_key hash (bcrypt) + ciphertext blobs
We cannot:  decrypt any user content without their private key

Self-hosted users skip encryption — their own machine, full control.
```

### Data layout (hosted, multi-tenant)

```
~/feedling-data/
├── users.json                    { api_key_hash → user_id, pubkey }
└── {user_id}/
    ├── frames/                   encrypted frame blobs
    ├── chat.json                 encrypted
    ├── identity.json             encrypted
    ├── memory.json               encrypted
    ├── tokens.json               APNs tokens (not content, no encryption needed)
    └── bootstrap.json
```

---

## Build Order

Everything below is sequential — each step depends on the previous.

---

### Step 1 — User registration + per-user data dirs

**Goal:** replace the flat single-user layout with per-user directories. Auth middleware resolves `api_key` → `user_id` on every request.

**New endpoint:**

```
POST /v1/users/register
Body: { "public_key": "<base64 pubkey>" }  ← optional for self-hosted
Returns: { "user_id": "usr_xxx", "api_key": "<random 32 bytes hex>" }
```

**users.json schema:**

```json
[
  {
    "user_id": "usr_abc123",
    "api_key_hash": "<bcrypt hash>",
    "public_key": "<base64>",
    "created_at": "2026-04-19T..."
  }
]
```

**Auth middleware (add to every route):**

```python
def get_current_user():
    key = request.headers.get("X-API-Key") or request.args.get("key")
    if not key:
        abort(401)
    user = resolve_user(key)   # bcrypt check against users.json
    if not user:
        abort(401)
    return user

def user_dir(user_id: str) -> Path:
    d = FEEDLING_DIR / user_id
    d.mkdir(parents=True, exist_ok=True)
    return d
```

**All file path references change from:**
```python
FEEDLING_DIR / "chat.json"
```
**to:**
```python
user_dir(current_user["user_id"]) / "chat.json"
```

This touches every endpoint but the logic inside each endpoint stays identical.

**Single-user self-hosted mode (backward compat):**

```python
SINGLE_USER = os.environ.get("SINGLE_USER", "false").lower() == "true"

# If SINGLE_USER=true: skip auth, use flat FEEDLING_DIR (current behavior)
# If SINGLE_USER=false (default for hosted): enforce auth, use per-user dirs
```

Self-hosted users set `SINGLE_USER=true` + their own `FEEDLING_API_KEY` in env. No registration endpoint needed for them.

---

### Step 2 — SSE endpoint on MCP server reads `?key=` from URL

**Goal:** `claude mcp add feedling --transport sse "https://mcp.feedling.app/sse?key=xxx"` works.

Currently `mcp_server.py` uses `transport="streamable-http"` with a single global API key from env. Change it so:

1. Switch transport to SSE (`transport="sse"`)
2. At connection time, read `key` from query param
3. Validate key against users.json (same bcrypt check as Flask)
4. Scope all MCP tool calls for that session to that user's data

FastMCP supports per-connection context. The key passed to the MCP session should be forwarded as `X-API-Key` header on every internal call to Flask.

The SSE endpoint URL pattern:
```
https://mcp.feedling.app/sse?key=<api_key>
```

Caddy routes `mcp.feedling.app` → `localhost:5002` (already in deploy/Caddyfile).

---

### Step 3 — iOS keypair generation + Settings UI

**Goal:** iOS app generates a keypair at first launch, stores private key in Keychain, and shows the agent setup string in Settings.

**First launch flow:**

```swift
// FeedlingTestApp.swift or onboarding view
if !hasRegistered {
    let keyPair = generateKeyPair()           // CryptoKit P-256 or Curve25519
    storePrivateKey(keyPair.private)          // iOS Keychain / Secure Enclave
    let result = await register(pubKey: keyPair.public)
    // result: { user_id, api_key }
    store(apiKey: result.api_key)
    store(userId: result.user_id)
    hasRegistered = true
}
```

**Settings tab additions:**

```
Storage
  ● Feedling Cloud  (default)
  ○ Self-hosted     [URL field]

Agent Setup
  ┌────────────────────────────────────────────────┐
  │ claude mcp add feedling --transport sse \      │
  │   "https://mcp.feedling.app/sse?key=<key>"    │
  └────────────────────────────────────────────────┘
  [Copy MCP string]

  For OpenClaw / HTTP agents:
  API URL:  https://api.feedling.app
  API Key:  <key>
  [Copy env vars]

  [Regenerate key]   [Delete my data]
```

Relevant files to modify:
- `testapp/FeedlingTest/FeedlingTestApp.swift` — first-launch check
- `testapp/FeedlingTest/FeedlingAPI.swift` — base URL + api key config
- `testapp/FeedlingTest/ContentView.swift` — Settings tab section

---

### Step 4 — SKILL.md self-hosted setup runbook

**Goal:** a pro user can tell their agent "set up Feedling on my VPS" and the agent follows the runbook in SKILL.md without any other instructions.

Add a "Self-Hosted Setup" section to `skill/SKILL.md`:

```markdown
## Self-Hosted Setup (Pro Users)

If the user wants to run their own Feedling server, follow these steps.
You need SSH access to their VPS.

1. Clone the repo
   git clone https://github.com/Account-Link/feedling-mcp-v1 ~/feedling-mcp-v1

2. Run the install script
   cd ~/feedling-mcp-v1 && bash deploy/setup.sh

3. Generate a strong API key
   openssl rand -hex 32
   → save this, you'll give it to the user

4. Set env vars
   mkdir -p ~/feedling-data
   echo "FEEDLING_API_KEY=<key>" > ~/feedling-data/.env
   echo "SINGLE_USER=true" >> ~/feedling-data/.env

5. Restart services
   systemctl --user restart feedling-backend feedling-mcp

6. Verify running
   curl http://localhost:5001/v1/push/tokens

7. Tell the user
   Server is ready.
   In your iOS app Settings → Storage → Self-hosted:
     URL: https://<your-domain>:5001
     Key: <key>
```

---

### Step 5 — HTTPS on feedling.app

**Goal:** `api.feedling.app` and `mcp.feedling.app` live behind TLS.

DNS (do in Namecheap):
```
api.feedling.app  A  <VPS IP>
mcp.feedling.app  A  <VPS IP>
```

Caddy config is already written at `deploy/Caddyfile`. Once DNS propagates:
```bash
sudo systemctl start caddy
```
Caddy auto-provisions Let's Encrypt certs. No manual cert work.

After this step, the full normal-user onboarding string works end-to-end.

---

## Key Files Reference

```
backend/app.py              All HTTP endpoints + business logic
backend/mcp_server.py       FastMCP SSE server (14 MCP tools)
backend/test_api.py         Full test suite — run after any backend change
                            python3 test_api.py http://54.209.126.4:5001

testapp/FeedlingTest/
  FeedlingTestApp.swift     App entry + APNs setup
  FeedlingAPI.swift         Base URL config
  ContentView.swift         4-tab root + Settings tab
  ChatView/ViewModel        Chat UI + polling
  IdentityView/ViewModel    Radar chart + 10s poll
  MemoryGardenView/VM       Moment cards + 10s poll
  LiveActivityManager.swift Live Activity lifecycle

deploy/
  Caddyfile                 HTTPS reverse proxy config
  setup.sh                  One-command VPS install
  feedling-backend.service  systemd for app.py
  feedling-mcp.service      systemd for mcp_server.py

skill/SKILL.md              Agent-facing docs (OpenClaw HTTP mode)
docs/NEXT.md                This file
```

---

## Test Suite

After any backend change, run:

```bash
python3 backend/test_api.py http://54.209.126.4:5001
```

Current coverage: screen/analyze, frames, tokens, chat send/history,
long-poll timeout + wake, full round-trip, bootstrap, identity CRUD, memory CRUD.

All 30 tests should pass before merging anything.

---

## What NOT to change

- WebSocket frame ingest logic (`/ws` handler in app.py)
- APNs push mechanism (JWT + .p8 key)
- Screen analyze keyword logic (`_semantic_analysis`)
- iOS UI tab structure (Chat / Identity / Garden / Settings)
- ScreenActivityAttributes.ContentState fields (title/subtitle/body/data)
- All existing endpoint URLs and response shapes (backward compat)

---

## After Steps 1–5: the E2E + TEE phase

`docs/DESIGN_E2E.md` (v0.3, decisions locked, targets ERC-733 Stage 1
DevProof) specifies how we get from "multi-tenant plaintext backend" to
"Feedling operationally cannot read your data and silent code updates are
impossible."  Summary:

- User-generated content keypair on iOS + enclave-generated content keypair.
- Every content item is wrapped under a random symmetric key; that key is
  sealed independently to (user pubkey, enclave pubkey) — the "double-wrap."
  AEAD additional-data binds ciphertext to `owner_user_id` to defeat
  cross-user ciphertext substitution by a malicious server.
- MCP server runs inside a **Phala-deployed dstack TDX CVM** and terminates
  TLS there. Caddy downgrades to SNI pass-through for `mcp.feedling.app`.
- **Authorization is enforced on-chain via an `AppAuth` contract on Base
  L2** (per `amiller/dstack-tutorial/05`). DstackKms refuses to release
  the enclave's content-privkey unless the running `compose_hash` is in
  the on-chain whitelist — so silent updates are architecturally
  impossible, not merely detectable.
- **iOS is the active auditor.** On every session, the phone runs the
  full `sxysun/is-this-real-tea` checklist against the live deployment
  (compose_hash match, AppAuth event log, compose reproduces, no
  operator-controllable env vars, TLS cert bound) and surfaces a card.
- **Indexing / aggregation compute runs on iOS by default.** Server-side
  compute is opt-in via user-placed enclave-cron jobs (Phase 6 and beyond).
- Migration is iOS-driven: the phone re-wraps old data after each enclave
  update; `compose_hash` changes are already published on-chain before
  rollout so the audit card just reflects the new authorized version.

Phase 1 (TEE infra + AppAuth deploy) is the blocker for everything else.
Don't start it until prod is running stably on multi-tenant mode from
this doc. Six phases total, ~6–7 weeks of engineering to Phase 5 cutover.
