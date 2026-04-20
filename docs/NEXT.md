# Feedling — What's Next

Last updated: 2026-04-20. Whoever picks this up — start here.

---

## What has shipped (as of 2026-04-20)

| Phase | Shipped | Commit |
|---|---|---|
| Phase 3 | TLS-in-enclave on attestation port 5003 | `4826ec7` |
| Phase A | Chat / memory / identity v1 envelope encryption end-to-end | `cc329a8` |
| Phase A.6 | Silent v0→v1 migration on first iOS launch post-update | `cc329a8` |
| Phase B | Privacy UX: onboarding (3 slides), Privacy page, export/delete/reset flows | `cc329a8` |
| Phase B wave-2 | Per-item visibility toggle (long-press on memory cards), migration progress row | `3a84867` |
| Phase C.1 | MCP in-enclave TLS on port 5002; `dstack_tls.py` shared cert derivation | `cc329a8` |
| Phase C.2 | ACME-DNS-01 inside the enclave — Let's Encrypt cert for `mcp.feedling.app`, key derived from dstack-KMS, never exported | `169cb6a` |
| Phase C.3 | `identity.nudge` v1 decrypt-mutate-rewrap in MCP; `chat.post_message` wraps to v1 | `cc329a8` |
| Docs | `AUDIT.md`, `MIGRATION.md`, `DESIGN.md`, `PHASE_B_PLAN.md`, GitHub footer links | `3a4acf5` |

CLI auditor `tools/audit_live_cvm.py`: **8/8 green** (Row 8 now verifies CA-valid LE cert for `mcp.feedling.app` + pubkey fp matches attested).
iOS audit card: **6/6 green** (with 8th row: MCP-port TLS bound to attestation).
Current CVM image: `ghcr.io/account-link/feedling:169cb6a`.
Current compose_hash on-chain: `0x23a2c2869567d15220383e4acb5ceb5cf27d78e087d2d4e357e4b3c053a5dc68`.

---

## What's still open, in priority order

### 1 — Task #23: Strip v0 code paths  ← DEFERRED

**Status: DEFERRED** — waiting for the one prod user (sxysun's friend, VPS SINGLE_USER=true) to install the updated iOS app and complete silent migration. `docs/MIGRATION.md` has her three options.

**What to strip once her migration completes:**
- `backend/app.py`: remove `POST /v1/chat/message` plaintext branch, `POST /v1/memory/add` plaintext branch, `POST /v1/identity/init` plaintext branch, `POST /v1/content/rewrap` endpoint itself, `_rewrap_chat()`, `_rewrap_memory_inplace()`, `_rewrap_identity()`.
- `backend/mcp_server.py`: remove v0 fallback branches in `memory_add_moment`, `chat_post_message`, `identity_init`.
- iOS `FeedlingAPI.swift`: remove v0 read/decode branches (the `if envelope == nil` fallback paths in the fetch/decode functions).
- iOS `FeedlingAPI.swift`: remove `runSilentV1MigrationIfNeeded()` itself and the `feedling.v1MigrationDone.*` UserDefaults key (after confirming migration ran once on all installed instances).
- All `v0` references in `docs/DESIGN_E2E.md`.

**Exit criterion:** `grep -r "v0\|plaintext\|rewrap" backend/` returns only comments; server never stores unencrypted content.

---

### 2 — Phase D: Eth Sepolia → Ethereum mainnet  ← DEFERRED (do last)

**Status: DEFERRED** — per user direction 2026-04-20 ("Eth mainnet migration last").  
**Pre-reqs:** Phase C part 2 shipped and stable ≥ 1 week; v0 strip done; hardware wallet in hand; no open security bugs.

**Decision to confirm before starting:** Base mainnet (L2, ~100× cheaper gas, faster finality) vs Ethereum L1 mainnet (higher perceived trust). User said "Eth mainnet" — verify they mean L1 vs L2 before spending gas.

**Steps (ready to execute when pre-reqs met):**
1. Fresh deployer keypair on hardware wallet — current `0xa0eBcd…` key is a throwaway (was pasted in chat Apr 19 per `DEPLOYMENTS.md`).
2. Redeploy `FeedlingAppAuth.sol` to chosen mainnet; `forge verify-contract` on Etherscan/Basescan.
3. `addComposeHash` batch for all historical hashes (so old iOS builds still pass audit).
4. Update `backend/enclave_app.py` APP_AUTH defaults + iOS pinned contract address + chain_id.
5. Ship iOS release with new pinned address ~1 week before cutover.
6. Update `deploy/DEPLOYMENTS.md` with mainnet entry.

---

## What NOT to change (guardrails)

- WebSocket frame ingest (`/ws` in `backend/app.py`) — working, don't touch.
- APNs push (JWT + `.p8` key) — working, don't touch.
- `ScreenActivityAttributes.ContentState` fields — changing breaks live activities on installed builds.
- Phase 3 TLS derivation path (`feedling-tls-v1`) in `dstack_tls.py` — changing breaks existing pinned attestations.
- `/v1/content/rewrap` endpoint — keep until Task #23 is confirmed done.
- Any endpoint URL or response shape used by existing released builds — add new endpoints instead.
- VPS prod (`ubuntu@54.209.126.4`, `openclaw`) — coordinate changes with user; one real user's data lives here.

---

## Key reference files

| File | Purpose |
|---|---|
| `docs/DESIGN_E2E.md` | Master architecture doc (v0.3) |
| `docs/CHANGELOG.md` | Landmark diffs with dates |
| `deploy/DEPLOYMENTS.md` | Every deployed artifact on VPS + CVM + chain |
| `HANDOFF.md` | Full current-state snapshot |
| `tools/audit_live_cvm.py` | Run after any enclave change — must be 8/8 before marking shipped |
| `docs/AUDIT.md` | Agent-consumable "is this safe?" guide |
| `docs/MIGRATION.md` | Three options for the one prod user |
| `DESIGN.md` | Design tokens + aesthetic — read before any UI change |
