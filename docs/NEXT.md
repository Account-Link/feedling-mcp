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
| v0 strip  | SINGLE_USER + v0 plaintext branches + `/v1/identity/nudge` HTTP + `/v1/content/rewrap` + `chat_bridge.py` + silent migration removed; `/v1/content/swap` replaces rewrap for visibility toggles | `<pending>` |
| Docs | `AUDIT.md`, `MIGRATION.md`, `DESIGN.md`, `PHASE_B_PLAN.md`, GitHub footer links | `3a4acf5` |

CLI auditor `tools/audit_live_cvm.py`: **8/8 green** (Row 8 now verifies CA-valid LE cert for `mcp.feedling.app` + pubkey fp matches attested).
iOS audit card: **6/6 green** (with 8th row: MCP-port TLS bound to attestation).
Current CVM image: `ghcr.io/account-link/feedling:169cb6a`.
Current compose_hash on-chain: `0x23a2c2869567d15220383e4acb5ceb5cf27d78e087d2d4e357e4b3c053a5dc68`.

---

## What's still open, in priority order

### 1 — Task #23: Strip v0 code paths  ← SHIPPED (2026-04-20)

**Status: SHIPPED** in the same cycle as tasks #34 (wipe VPS) and #35 (rebuild CVM).
The one real prod user okayed a full data wipe + fresh reinstall, so rather
than keep rewrap as a compatibility shim we retired the whole v0 stack:

- `backend/app.py`: dropped all SINGLE_USER branches, v0 plaintext accept
  branches in chat/memory/identity writes, `/v1/content/rewrap`, all
  `_rewrap_*` helpers, and the HTTP `/v1/identity/nudge` endpoint (moved to
  MCP `feedling.identity.nudge` inside the enclave). `/v1/content/swap`
  replaces rewrap for ongoing visibility toggles (same validation shape,
  no v0→v1 status codes).
- `backend/mcp_server.py`: dropped the `SINGLE_USER` constant and every
  v0 fallback branch in `chat_post_message`, `identity_init`, `memory_add_moment`,
  `identity_nudge` — they now fail loud if pubkeys aren't available.
- `backend/enclave_app.py`: dropped `if v == 0:` pass-throughs in chat, memory,
  and identity decrypt loops.
- `backend/chat_bridge.py` + `deploy/feedling-chat-bridge.service`: deleted.
  MCP's in-enclave `feedling.chat.post_message` replaces them.
- `deploy/docker-compose.yaml`, `docker-compose.phala.yaml`, `setup.sh`,
  `feedling.env.example`: dropped `SINGLE_USER` + shared `FEEDLING_API_KEY`.
- iOS `FeedlingAPI.swift`: removed `runSilentV1MigrationIfNeeded`,
  `RewrapSummary`, v0 collectors, `postRewrap`, `migrationProgress` @Published,
  and the 403-SINGLE_USER branch in `ensureRegisteredIfCloud`.
  `flipMemoryVisibility` now POSTs to `/v1/content/swap`.
  `ContentView.swift`: removed `MigrationProgressRow` and its usage.
  `FeedlingTestApp.swift`: removed the migration kickoff call.
  `ChatViewModel.swift`, `SampleHandler+WebSocketQueue.swift`: removed
  plaintext fallbacks (backend now rejects them with 400 / drops silently).
  Dead `WebSocketManager.sendFrame(IngestFramePayload)` removed.
- `backend/test_api.py`: removed `/v1/identity/nudge` cases, added header
  note that write-path tests need an envelope-aware rewrite.
- `tools/e2e_encryption_test.py`, `.github/workflows/ci.yml`: dropped
  `SINGLE_USER` env + CI matrix row.
- `/v1/content/export` now includes frames (full v1 envelopes inlined),
  schema bumped to 2, byte cap raised 50→80 MiB.

**Exit criterion hit:** `grep -r "SINGLE_USER\|single_user" backend/ deploy/` → no hits (outside historical changelog entries). Server never stores unencrypted content.

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
- `/v1/content/swap` endpoint — used by iOS `flipMemoryVisibility`; don't rename.
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
