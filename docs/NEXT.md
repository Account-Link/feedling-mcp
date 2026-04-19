# Feedling — Next Build Phase (post-Phase 3)

Read this alone and you have everything needed to continue. The previous
`NEXT.md` (multi-tenant backend + MCP SSE + iOS onboarding) shipped on
2026-04-19; Phase 1-3 of the TDX E2E plan (`docs/DESIGN_E2E.md`) shipped
between 2026-04-19 and 2026-04-20. See `docs/CHANGELOG.md` for the
landmark diffs.

## Current state (2026-04-20)

- Flask + MCP SSE live on `api.feedling.app` / `mcp.feedling.app` (VPS,
  multi-tenant, bcrypt-hashed keys, per-user dirs).
- Phala TDX CVM (`feedling-enclave`, UUID `4386636e-…`) runs
  `ghcr.io/account-link/feedling:451b5b0`. `/attestation` terminates
  TLS **inside** the enclave (compose_hash `0xb0fb1f84…`, cert fingerprint
  `5698f0ade4bb412d…`). On-chain: Eth Sepolia
  `0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F`.
- iOS audit card: **6/6 green**. CLI auditor (`tools/audit_live_cvm.py`):
  **7/7 green**. Evidence: `docs/screenshots/audit_card_phase3_tls_pinned.png`.
- Frame content (screen recording) is end-to-end encrypted via iOS
  `ContentEncryption.swift` → v1 envelope → server stores ciphertext;
  enclave decrypts on behalf of agents.

## What's still plaintext

- Chat messages, identity card, memory garden — the iOS envelope code
  exists, the enclave decrypt endpoints exist, but the iOS write paths
  still POST plaintext. Server stores plaintext too.
- MCP SSE TLS (`mcp.feedling.app` and `-5002.`) terminates at
  Caddy / dstack-gateway, not inside the enclave.
- Privacy UX is technically accurate but not beta-user-friendly — no
  onboarding explanation, no per-item visibility, no export/delete.

---

## Plan — four phases, in order

Do them sequentially; each ends in a user-visible shipped state that
doesn't regress any earlier guarantee.

### Phase A — Content encryption rollout (~1–2 weeks)

**Goal:** chat, memory, identity all flow through the v1 envelope layer
end-to-end. Backend never sees plaintext content again; agents read via
the enclave's decrypt endpoints.

**Work:**
1. iOS write paths wrap before POST:
   - `ChatViewModel.sendMessage` → wrap body, POST envelope to `/v1/chat/message`
   - `IdentityViewModel.init/nudge` → wrap to `/v1/identity/init` / `/nudge`
   - `MemoryViewModel.add` → wrap to `/v1/memory/add`
   Envelope code is already in `ContentEncryption.swift`; see frame
   broadcast extension (`FrameEnvelope.swift`) for the pattern.
2. Backend write handlers accept v1 envelopes (chat/memory/identity
   already accept on frame ingest; mirror for these three paths).
3. iOS read paths:
   - Shared-visibility items → fetch plaintext from the enclave decrypt
     endpoints (`/v1/chat/history`, `/v1/memory/list`, `/v1/identity/get`
     on the CVM origin, NOT the VPS Flask).
   - `local_only` items → decrypt on-device from ciphertext fetched off
     the VPS.
4. Migration:
   - On first launch post-update, iOS reads its own legacy plaintext,
     wraps it, PUTs envelopes back, and deletes the plaintext. Show
     progress in Settings → Privacy → "Upgrading your data".
   - Per-user, incremental, non-blocking; retry on failure.
5. Retire v0:
   - Mark plaintext write endpoints deprecated; keep reads for 30 days
     in case of rollback.
   - After 30 days and no regressions, delete plaintext paths from
     `backend/app.py`.

**Test plan:**
- Extend `backend/test_api.py` to write/read via v1 envelopes and assert
  the server-side blob is ciphertext.
- `tools/v1_envelope_roundtrip_test.py` already covers
  chat/memory/identity roundtrip; make it CI-gated.
- iOS: cold install → agent calls `feedling.memory.list` → plaintext
  comes back. Inspect server blob via SSH, confirm ciphertext.
- Migration: manual dev — seed a /tmp/fl dir with legacy plaintext,
  launch iOS, confirm re-wrap + plaintext deletion.

**Exit criterion:** a Feedling operator with full root on the VPS cannot
read any content the user has written post-migration. No v0 plaintext
endpoints remain in `backend/app.py`.

### Phase B — Privacy UX + onboarding (~1 week, ideally after a design review)

**Goal:** a first-run user understands what Feedling can and cannot see,
can exercise control (export, delete, visibility, self-hosted), and the
privacy-card copy is production-quality.

**Work:**
1. Run `/plan-design-review` on the proposed onboarding + Privacy
   settings layout BEFORE implementing. The current audit card copy was
   drafted in-session and needs a pass for product voice (flagged in
   HANDOFF.md).
2. Onboarding (new flow, first-run only, dismissable):
   - Slide 1: "What lives on your phone" — chat history, memory garden,
     identity card. Your device, your keys.
   - Slide 2: "What Feedling sees (and why it can't read it)" — encrypted
     envelopes + enclave model in one diagram. Link to audit card.
   - Slide 3: "You're in control" — export, delete, self-host.
     Highlight the "Run your own server" option.
3. Settings → Privacy redesign:
   - Audit card stays (already built).
   - **Export my data** button → tgz of all content (decrypted client-side).
   - **Delete my data** → hard delete on server + revoke api_key + local wipe.
   - **Per-item visibility toggles** on memory / chat items (designed in
     DESIGN_E2E §12.3; shared is default).
   - **Migration status** progress bar when Phase A's re-wrap is in
     flight.
   - **MRTD-changed review card** — when enclave measurements change
     between sessions, block key usage until the user taps "I reviewed
     the change."
4. "Run your own" branch:
   - Prominent in Settings → Storage (already partially there).
   - Onboarding slide 3 links to `skill/SKILL.md` runbook with a
     "Send this to my agent" button (copies the runbook + SSH prompt).

**Test plan:** first-run UX walkthrough on fresh-install sim; copy
review sign-off by @sxysun; accessibility pass (VoiceOver for the
audit card + toggles).

**Exit criterion:** a fresh-install beta user completes onboarding and
can articulate "what Feedling can see" and "how I'd run my own." Audit
card copy approved by sxysun.

### Phase C — MCP into TEE (~3–5 days)

**Goal:** Claude.ai / Claude Desktop's MCP connection to Feedling
terminates TLS inside the CVM, so the audit card's TLS row extends to
the MCP port. Envelope crypto already protects content; this closes the
metadata-plaintext gap for agent ↔ enclave traffic.

**Work:**
1. FastMCP is already in the enclave CVM (see `docker-compose.phala.yaml`
   `mcp` service). What's missing is in-enclave TLS serving on that port.
2. TLS path — decide between:
   - **(a)** Use Phala's `-5002s.` passthrough suffix with the same
     dstack-KMS-derived cert as attestation; iOS + Claude.ai see a
     self-signed cert.
     *Problem:* Claude.ai expects a browser-trusted CA chain. Won't work
     without a shim.
   - **(b)** ACME-DNS-01 inside the enclave against `mcp.feedling.app`
     via Cloudflare or Namecheap DNS API. Lets Encrypt issues a real
     cert; private key lives only in CVM memory.
     *Needs:* DNS API token (security-audit: does token give too much
     access?), renewal logic (certs expire every 90 days).
   - **(c)** Keep Caddy on the VPS but downgrade `mcp.feedling.app` to
     `layer4` SNI passthrough → Phala gateway → enclave. Enclave does
     its own ACME. Caddy never sees plaintext.
   - *Default:* **(c)** — minimal disruption to existing Caddy setup,
     real CA cert, enclave-held key.
3. Extend the audit card / CLI auditor to pin MCP port's TLS too.

**Test plan:** Claude.ai adds MCP connector; cert fingerprint pinned in
bundle matches handshake; audit card row "MCP TLS bound to attestation"
goes green.

**Exit criterion:** two green TLS rows (attestation + MCP); full metadata
path runs through attested TLS.

### Phase D — Eth Sepolia → Ethereum mainnet migration (~1–2 days, DO LAST)

**Goal:** on-chain authorization lives on a chain with real economic
finality and validator set, removing the testnet-sunset / reorg risk.

**Note:** `docs/DESIGN_E2E.md` §12.14 originally proposed **Base mainnet**
(Ethereum L2, cheaper gas). User direction on 2026-04-20 was "Eth mainnet."
Before starting D, confirm: Base mainnet (L2) vs Ethereum L1 mainnet.
L2 has ~100× lower gas for `addComposeHash` + faster finality; L1 has
higher perceived trust for end users. Defer the decision until A-C ship.

**Work:**
1. Fresh deployer keypair on hardware wallet (Ledger / Trezor / similar).
   Current Sepolia deployer `0xa0eBcd26D7816D68a74b0CdC8037C16F8fcbF9C0`
   is a throwaway (per DEPLOYMENTS.md §Phase 1 testnet) and must not be
   reused.
2. Redeploy `FeedlingAppAuth` to the chosen mainnet; `forge verify-contract`
   on Etherscan/Basescan.
3. Batch `addComposeHash` for all historical hashes (initial + rehashes
   + Phase 3) so users verifying older iOS builds still pass audit.
4. Update `backend/enclave_app.py` APP_AUTH defaults + iOS pinned
   contract address + chain_id.
5. Ship iOS release with new pinned address ~1 week before the actual
   cutover so accept-list is pre-approved. Same for CLI auditor.
6. Update `deploy/DEPLOYMENTS.md` with the mainnet entry.

**Pre-reqs (what needs to be green before starting D):**
- Phase A shipped and stable ≥ 1 week — no rollback in flight.
- Phase B shipped and onboarding/copy approved — users about to be
  migrated have reviewed the privacy model.
- Phase C shipped — audit card at full green including MCP TLS.
- Hardware wallet procured + deployer key generated.
- Etherscan (or Basescan) API key in hand.
- No active security-relevant bugs open.

**Exit criterion:** audit card shows "authorized on Ethereum mainnet"
(or Base mainnet); DEPLOYMENTS.md `Phase 5 production cutover` section
filled in; Sepolia contract kept as archive pointer only.

---

## Summary: what's left before Phase D (Eth mainnet)

| Phase | Scope | Est. | Blocker for D? |
|---|---|---|---|
| A | Content encryption rollout | 1-2 weeks | Yes |
| B | Privacy UX + onboarding | 1 week | Yes |
| C | MCP into TEE | 3-5 days | Yes |
| D | Eth Sepolia → Eth mainnet | 1-2 days | — |

Total to D: **~3-4 weeks** of engineering if single-threaded, plus
review/copy cycles in Phase B. Anything that reaches the "shipped"
state from A/B/C can release to users incrementally — don't block on
all of them landing simultaneously.

## What NOT to change

- WebSocket frame ingest logic (`/ws` handler in `backend/app.py`).
- APNs push mechanism (JWT + .p8 key, `~/feedling/AuthKey_*.p8`).
- Screen analyze keyword logic (`_semantic_analysis`).
- iOS UI tab structure (Chat / Identity / Garden / Settings).
- `ScreenActivityAttributes.ContentState` fields.
- Any endpoint URL or response shape used by existing released builds
  (add new endpoints instead).
- Phase 3 enclave TLS derivation (`feedling-tls-v1`) — changing the
  path would break existing pinned attestations.

## Reference

- `docs/DESIGN_E2E.md` — master architecture doc, now v0.3 with Phase 3
  marked partially shipped.
- `docs/CHANGELOG.md` — landmark diffs with dates.
- `deploy/DEPLOYMENTS.md` — every deployed artifact on VPS + CVM + chain.
- `HANDOFF.md` — current-state snapshot for next agent pickup.
- `tools/audit_live_cvm.py` — run this after any enclave change to
  confirm 7/7 before marking shipped.
