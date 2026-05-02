# feedling-mcp-v1

Feedling gives your Personal Agent a body on iOS — Dynamic Island, Live
Activity, Chat, Identity Card, Memory Garden — with server-side content
encrypted at rest inside an **Intel TDX enclave** whose compose image is
authorized on-chain and verified live from the app.

Agent 是大脑，Feedling 是身体。

## What this repo is

1. **Flask HTTP backend** (`backend/app.py`) — iOS + HTTP-skill agent API
2. **FastMCP server** (`backend/mcp_server.py`) — MCP protocol for Claude.ai / Claude Desktop
3. **Enclave app** (`backend/enclave_app.py`) — TDX-CVM process that holds the content private key, terminates its own TLS, and runs the decrypt proxy
4. **iOS app** (`testapp/`) — Chat · Identity · Garden · Settings, plus Live Activity / Dynamic Island, Broadcast Extension for screen capture, and a live **audit card** that re-verifies the enclave on every open
5. **Skill** (`skill/SKILL.md`) — main loop spec for all agent modes (MCP via Claude.ai / Claude Desktop, and HTTP-mode agents via OpenClaw / Hermes)
6. **Contracts** (`contracts/`) — `FeedlingAppAuth` on Ethereum Sepolia, the on-chain allow-list of authorized `compose_hash`es
7. **Tools** (`tools/`) — `audit_live_cvm.py` CLI that mirrors the iOS audit checks; DCAP verifier; envelope round-trip tests

```
feedling-mcp-v1/
├── backend/        ← Flask (5001) + FastMCP (5002) + enclave_app (5003)
├── testapp/        ← iOS SwiftUI app + Widget + Broadcast Extension
├── deploy/         ← docker-compose.yaml (host) + docker-compose.phala.yaml (CVM)
│                     + Caddyfile + systemd + setup.sh + DEPLOYMENTS.md
├── contracts/      ← FeedlingAppAuth (Solidity, Sepolia)
├── tools/          ← audit_live_cvm.py + DCAP verifier + envelope tests
├── docs/           ← DESIGN_E2E.md · AUDIT.md · CHANGELOG.md · MIGRATION.md
├── skill/          ← SKILL.md for OpenClaw (HTTP mode)
├── HANDOFF.md      ← current state — read this first
├── DESIGN.md       ← visual / UI design tokens
└── CLAUDE.md       ← repo-level conventions for Claude Code
```

---

## What guarantees does Feedling give you?

The trust story, in one page. Full derivation in
`docs/DESIGN_E2E.md`; live-verify procedure in `docs/AUDIT.md`.

1. **Content-at-rest is ciphertext.** Chat, memory moments, identity
   card, agent nudges, agent replies, screen frames — every write path
   wraps the payload into a **v1 envelope**
   `{v, body_ct, nonce, K_user, K_enclave, enclave_pk_fpr, visibility,
   owner_user_id}` before hitting disk. `body_ct` is ChaCha20-Poly1305
   with a random per-message CEK. The CEK is wrapped twice — once to
   the user's per-device content key (so the phone can always read),
   once to the enclave's content pubkey (so agents reading via the
   decrypt proxy only see plaintext inside TDX). The backend rejects
   plaintext writes with `400 plaintext_write_rejected`.

2. **Keys are bound to the enclave, not the operator.** The enclave's
   content private key and TLS private key are derived from
   **dstack-KMS** inside the TDX CVM at boot. The operator of the
   Phala host, the VPS root, and anyone with DB access see only
   ciphertext and public keys. Keys stay stable across compose
   updates for this `app_id`, so `compose_hash` rotations don't
   trigger a user-visible rewrap dance.

3. **Which code is actually running is provable.** The enclave
   produces a DCAP-signed TDX **attestation quote**. `REPORT_DATA`
   in that quote binds:
   - `enclave_content_pk` (sha256 of the public key the app wraps
     CEKs to — so you can't be MITM'd onto a different pubkey)
   - `sha256(attestation-port TLS cert DER)` (so the iOS app pins
     the exact cert it's talking to)
   - `mcp_tls_cert_pubkey_fingerprint_hex` (SPKI sha256 of the
     **MCP-port Let's Encrypt cert's public key** — that key is
     derived from dstack-KMS at path `feedling-mcp-tls-v1`, so it
     survives 90-day LE renewals)
   RTMR3 event-log replay proves that the `compose_hash` measured
   into the quote matches the compose file in this repo.

4. **The running image is authorized on-chain.** The image's
   `compose_hash` must be present in `FeedlingAppAuth` on Ethereum
   Sepolia (`0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F`) — anyone
   can inspect `addComposeHash(...)` history to see every image
   that was ever authorized to serve Feedling users. The on-chain
   log is **public transparency**, not the security boundary: the
   real boundary is the DCAP quote + `compose_hash` binding.

5. **MITM is detectable, not implicitly trusted.** iOS pins the
   live attestation-port cert's `sha256(DER)` to the fingerprint
   in the quote, and pins the live MCP-port LE cert's SPKI sha256
   to the fingerprint in the quote. Network-level interception
   surfaces as a failed audit row, not silent compromise.

6. **Multi-tenant isolation.** Each user is registered via
   `POST /v1/users/register`, gets an api_key, and lives under
   `~/feedling-data/<user_id>/`. API keys are stored as
   **HMAC-SHA256** (32-byte `.pepper`, `chmod 600`). Envelopes
   carry `owner_user_id`; the backend rejects cross-tenant reads.

---

## How to verify those guarantees

Three independent paths — any one of them is sufficient, all three
together give you defense in depth.

### 1. iOS audit card (on-device, one tap)

Open the app → Settings → **Privacy → Audit card**. 8 rows turn
green live against the running CVM:

1. `/attestation` reachable + parses
2. DCAP quote chains to Intel SGX Root CA
3. Measurements non-zero + `mr_config_id[0]=0x01`
4. `compose_hash` authorized on `FeedlingAppAuth` (Sepolia)
5. RTMR3 event log replay matches `compose_hash` + `mr_config_id`
6. Attestation-port TLS cert `sha256(DER)` matches REPORT_DATA
7. MCP-port Let's Encrypt cert verifies against the public CA *and*
   its SPKI sha256 matches the attested pubkey fingerprint
8. All cryptographic signatures check out

Canonical reference screenshot:
`docs/screenshots/audit_card_phase3_tls_pinned.png` (6/6 card,
pre–Phase C.2). Current deploy is 8/8 green.

### 2. Command-line auditor (anyone, no iOS required)

```bash
cd tools
uv run audit_live_cvm.py --cvm-url https://<cvm-host>-5003s.dstack-pha-prod5.phala.network
```

Mirrors all 8 rows of the iOS card. Good for CI, third-party
reviewers, and agent-driven verification.

### 3. Read the source on GitHub

The image running in the CVM is
`ghcr.io/account-link/feedling:<git-commit>` (public). The git
commit is baked into the image and surfaced in
`GET /attestation` as `git_commit`. Compare to this repo's
`git log` — if it doesn't match, don't trust the card.

---

## Status (as of 2026-05-02)

Read `HANDOFF.md` for the current snapshot. TL;DR:

**Shipped (Phases A–D + post-launch)**
- [x] v0/SINGLE_USER strip — multi-tenant only; plaintext writes return 400
- [x] iOS end-to-end: chat / memory / identity / nudges / agent replies all v1 envelopes
- [x] TDX CVM live on Phala Cloud with on-chain `compose_hash` authorization
- [x] In-enclave TLS on both attestation (5003) and MCP (5002) ports
- [x] ACME-DNS-01 inside the CVM — Let's Encrypt cert with private key provably inside TDX
- [x] iOS audit card 8/8 green; `tools/audit_live_cvm.py` 8/8 green
- [x] CI: `backend/test_api.py` rewritten for envelope-only backend, green on GitHub Actions
- [x] Prod user migrated to multi-tenant on current image; registration race fixed
- [x] Screen recording (Broadcast Extension) — encrypted frame ingest, agent reads via `decrypt_frame`
- [x] Live Activity / Dynamic Island — agent push + chat sync; onboarding slide to enable
- [x] Proactive messaging loop — semantic-first screen analysis, agent decides when to reach out
- [x] Push preference system — agent asks during bootstrap, stores in `signature` on Identity page
- [x] Memory Garden: unread dots (persistent), month badge right-aligned, bilingual copy
- [x] Identity page: `signature` field displayed; bilingual empty state
- [x] SKILL.md: main loop spec for both MCP and HTTP agents; memory quality rewrite (friend test)

**Deferred (Phase E, post-launch)**
- [ ] Migrate on-chain `FeedlingAppAuth` to Ethereum mainnet
- [ ] Claude.ai connector submission

---

## Architecture

```
Claude.ai / Claude Desktop       OpenClaw / Hermes / HTTP agents
        │                               │
        │ MCP SSE (port 5002 / TLS)     │ HTTP + SKILL.md (port 5001 / TLS)
        ▼                               ▼
┌──────────────────────────────────────────────────────────┐
│                         VPS host                         │
│  Caddy  ──►  backend (Flask, 5001)                       │
│         ──►  mcp     (FastMCP SSE, 5002, →  backend)     │
└──────────────────────────────────────────────────────────┘
        │ APNs (JWT + .p8)       ▲ WebSocket (port 9998, Bearer api_key)
        ▼                        │
┌──────────────────────────────────────────────────────────┐
│                       iPhone (iOS)                       │
│  Chat │ Identity │ Garden │ Settings (Audit card)        │
│  Dynamic Island / Live Activity · Broadcast Extension    │
└──────────────────────────────────────────────────────────┘

                                         TDX CVM (Phala dstack)
                                         ┌──────────────────────┐
    iOS audit card ──pins sha256(DER)──► │ enclave_app (5003)   │
    MCP reads (decrypt proxy)  ────────► │   content priv key   │
    LE cert (mcp.feedling.app, 5002) ──► │   from dstack-KMS    │
                                         │   REPORT_DATA bakes: │
                                         │   - content_pk_fpr   │
                                         │   - tls cert_der_fpr │
                                         │   - mcp spki fpr     │
                                         └──────────────────────┘
                                              │
                                              │ compose_hash authorized
                                              ▼
                                    FeedlingAppAuth (Sepolia)
                                    0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F
```

---

## Backend

### Processes

| Process | File | Port | Purpose |
|---------|------|------|---------|
| Flask backend | `backend/app.py` | 5001 | iOS + agent HTTP API, envelope storage |
| MCP server | `backend/mcp_server.py` | 5002 | MCP SSE for Claude.ai / Claude Desktop |
| Enclave app | `backend/enclave_app.py` | 5003 | TDX CVM: `/attestation`, decrypt proxy, MCP-port TLS |

The host-side `backend` and `mcp` services run on the VPS and proxy
via Caddy. The `enclave` service is deployed separately to a Phala
CVM using `deploy/docker-compose.phala.yaml` — that file's
`compose_hash` is what the on-chain contract authorizes.

There is **no** `chat_bridge.py` anymore. Retired 2026-04-20 when
MCP's `feedling.chat.post_message` landed and agent replies started
wrapping to v1 envelopes directly inside the CVM.

### Run (quick start)

**Docker / docker-compose (host services):**

```bash
cp deploy/feedling.env.example deploy/.env   # APNs, public base URL, etc.
docker compose -f deploy/docker-compose.yaml --env-file deploy/.env up -d --build
```

Brings up `backend` (5001) + `mcp` (5002). Data persists in the
named volume `feedling_data` (mounted at `/data`). Drop the APNs
`.p8` into that volume to enable push.

**Phala CVM (enclave):**

```bash
phala deploy -c deploy/docker-compose.phala.yaml -n feedling-enclave \
  -e CF_ZONE_ID=... -e CF_API_TOKEN=...
bash deploy/publish-compose-hash.sh   # authorize on-chain
```

See `deploy/DEPLOYMENTS.md` for the full enclave redeploy runbook
and `docs/AUDIT.md` for the live-verify procedure.

**Bare-metal / systemd (host only):**

```bash
bash deploy/setup.sh [--install-caddy]
```

Creates a venv under `~/feedling-venv`, installs deps, writes
`~/feedling.env` (multi-tenant — no shared API key), and starts
`feedling-backend` + `feedling-mcp` systemd units.

### HTTP endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/users/register` | Multi-tenant registration → returns per-user `api_key` |
| POST | `/v1/bootstrap` | First-connection trigger; returns instructions for Agent |
| GET | `/v1/identity/get` | Read identity envelope |
| POST | `/v1/identity/init` | Write identity envelope (once, 5 dimensions) |
| POST | `/v1/identity/replace` | Decrypt-mutate-rewrap landing point (MCP orchestrates) |
| GET | `/v1/memory/list` | List memory envelopes |
| GET | `/v1/memory/get` | Get one envelope by id |
| POST | `/v1/memory/add` | Add a memory envelope |
| DELETE | `/v1/memory/delete` | Delete a moment by id |
| POST | `/v1/content/swap` | In-place envelope swap (visibility toggles) |
| GET | `/v1/content/export` | Export all user content as envelopes |
| POST | `/v1/account/reset` | Wipe this user's data + rotate api_key |
| GET | `/v1/screen/analyze` | Semantic-first screen analysis + `rate_limit_ok` |
| GET | `/v1/screen/summary` | Today's screen-time rollup (top app, minutes, pickups) |
| GET | `/v1/screen/frames/latest` | Latest frame metadata (v1 envelope; image is ciphertext) |
| GET | `/v1/screen/frames` | List recent frames (metadata only) |
| GET | `/v1/screen/frames/<id>/decrypt` | Enclave decrypt → plaintext OCR + optional base64 JPEG |
| GET | `/v1/screen/frames/<id>/image` | Raw JPEG bytes, `Accept-Ranges: bytes` for parallel fetch |
| POST | `/v1/push/dynamic-island` | Push to Dynamic Island |
| POST | `/v1/push/live-activity` | Update Live Activity |
| GET | `/v1/push/tokens` | List registered APNs tokens |
| POST | `/v1/push/register-token` | iOS app registers APNs token |
| GET | `/v1/chat/history` | Fetch chat envelopes |
| POST | `/v1/chat/message` | User sends a message envelope (iOS app) |
| POST | `/v1/chat/response` | Agent posts a reply envelope |
| GET | `/v1/chat/poll` | Long-poll: blocks until user message |

All write endpoints that take content enforce v1 envelope shape and
reject plaintext with `400 plaintext_write_rejected`.

### MCP tools (17 total)

| Tool | Maps to |
|------|---------|
| `feedling.bootstrap` | POST /v1/bootstrap |
| `feedling.identity.init` | POST /v1/identity/init |
| `feedling.identity.get` | GET /v1/identity/get (decrypted via enclave proxy) |
| `feedling.identity.nudge` | in-CVM decrypt-mutate-rewrap → POST /v1/identity/replace |
| `feedling.memory.add_moment` | POST /v1/memory/add (wraps to v1 inside CVM) |
| `feedling.memory.list` | GET /v1/memory/list |
| `feedling.memory.get` | GET /v1/memory/get |
| `feedling.memory.delete` | DELETE /v1/memory/delete |
| `feedling.push.dynamic_island` | POST /v1/push/dynamic-island |
| `feedling.push.live_activity` | POST /v1/push/live-activity |
| `feedling.screen.latest_frame` | GET /v1/screen/frames/latest (metadata only) |
| `feedling.screen.frames_list` | GET /v1/screen/frames (metadata only; encrypted) |
| `feedling.screen.analyze` | GET /v1/screen/analyze |
| `feedling.screen.summary` | GET /v1/screen/summary |
| `feedling.screen.decrypt_frame` | GET /v1/screen/frames/<id>/decrypt — Image block + OCR for agent vision |
| `feedling.chat.post_message` | wraps to v1 envelope → POST /v1/chat/response |
| `feedling.chat.get_history` | GET /v1/chat/history |

The `?key=<api_key>` on the SSE URL is captured by an ASGI
middleware on the first GET and pinned to the MCP session — every
subsequent tool call is routed as that user.

---

## iOS app

### Tab structure

| Tab | Content |
|-----|---------|
| Chat | Real-time conversation with Agent |
| Identity | Agent's 5-dimension personality card (pentagon radar) |
| Garden | Memory garden — long-press a card to toggle visibility |
| Settings | Storage mode, API info, Privacy hero (audit card, export, delete, reset) |

### Setup (first time)

1. Open `testapp/FeedlingTest.xcodeproj` in Xcode
2. For each target: sign with your team, verify App Groups = `group.com.feedling.mcp`
3. Plug in iPhone (iOS 16.2+) → Build & Run

### `ContentState` (Live Activity / Dynamic Island)

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

---

## Bootstrap flow (aha moment)

1. Agent calls `POST /v1/bootstrap`
2. Backend returns `first_time` + instructions
3. Agent calls `feedling.identity.init` → writes 5-dimension personality card as v1 envelope
4. Agent searches its own memory → calls `feedling.memory.add_moment` 3-5 times
5. Agent calls `feedling.chat.post_message` → "I'm here, go check the app"
6. Agent asks the user how they want to be reached proactively → writes a `signature` (one sentence in the agent's own voice) into the identity card
7. iOS app detects identity envelope appeared → auto-switches to Identity tab
8. User sees: filled radar + memory garden + chat message + agent's signature

### Memory Garden quality standard

Ask: *"If I were telling a mutual friend a story about this person, would I tell this one?"*

A strong memory answers at least one of:
- When did I first understand something real about them?
- What did they say that I still think about?
- When was the first time something meaningful happened between us?
- When did something shift in how we relate?

Writing guidance: narrate from inside the moment, not from outside it. The topic can involve work — but the *point* must be about the person or the relationship. Avoid synthetic test content in production gardens.

---

## Agent setup

### Claude.ai / Claude Desktop (SSE MCP)

Cloud users get a one-liner from the iOS app's **Settings → Agent
Setup → Copy MCP string**:

```
claude mcp add feedling --transport sse "https://mcp.feedling.app/sse?key=<api_key>"
```

Self-hosted users derive the same shape using their own domain:

```
claude mcp add feedling --transport sse "https://mcp.<your-domain>/sse?key=<api_key>"
```

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

Self-hosted users: see `skill/SKILL.md` → **Self-Hosted Setup** for
an end-to-end SSH runbook an agent can follow to deploy the server
itself.

---

## Config reference

| Variable | Value |
|----------|-------|
| `FEEDLING_API_URL` | `http://localhost:5001` (VPS local) |
| `FEEDLING_DATA_DIR` | `~/feedling-data/` |
| `FEEDLING_MCP_TRANSPORT` | `sse` (default) or `streamable-http` |
| Flask port | `5001` |
| MCP port | `5002` |
| Enclave port | `5003` (in CVM only) |
| WebSocket port | `9998` |
| App Group | `group.com.feedling.mcp` |
| Team ID | `DC9JH5DRMY` |
| Main bundle ID | `com.feedling.mcp` |
| APNs Key ID | `5TH55X5U7T` |
| APNs `.p8` path | `~/feedling-data/AuthKey_5TH55X5U7T.p8` (`chmod 600`) |

### Multi-tenant data layout

```
~/feedling-data/
├── users.json                  # [{user_id, api_key_hash, public_key, created_at}, …]
├── .pepper                     # 32-byte HMAC secret, chmod 600
├── AuthKey_5TH55X5U7T.p8       # APNs key, chmod 600
└── <user_id>/
    ├── frames/                 # per-user screen frame envelopes
    ├── chat.json               # v1 envelopes
    ├── identity.json           # v1 envelope
    ├── memory.json             # v1 envelopes
    ├── tokens.json             # APNs tokens (not content — no encryption needed)
    ├── push_state.json
    ├── live_activity_state.json
    ├── bootstrap.json
    └── bootstrap_events.jsonl
```

`users.json`, `.pepper`, and the APNs `.p8` are the only files
outside a user directory.

---

## Where to go next

| If you want to … | Read |
|---|---|
| Know the current state of the project | `HANDOFF.md` |
| Understand the full encryption / enclave design | `docs/DESIGN_E2E.md` |
| Verify the running enclave yourself | `docs/AUDIT.md` |
| Redeploy the CVM or rotate `compose_hash` | `deploy/DEPLOYMENTS.md` |
| See landmark diffs by session | `docs/CHANGELOG.md` |
| Work on visuals / UI | `DESIGN.md` |
| Move an existing self-hosted user to Feedling Cloud | `docs/MIGRATION.md` |
| Set up a resident chat consumer for an HTTP/CLI agent | `skill/SKILL.md § Chat Resident Consumer` |
| Diagnose why chat messages aren't getting replies | `python tools/check_chat_pipeline.py` |
