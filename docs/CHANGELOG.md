# Feedling MCP — Changelog

> Landmark diffs over time. Two months from now, this is how we remember
> when a decision was made and why.
>
> Source-of-truth for "where we are now" is `HANDOFF.md`.
> `PROJECT_BRIEF.md` and `ROADMAP.md` were retired 2026-04-20 — historical
> references to them below are preserved verbatim.

---

## 给 Claude Code 的说明

**每次开新对话时**，请按顺序读：
1. `HANDOFF.md`（当前状态 + 下一步 + guardrails）
2. `CHANGELOG.md`（最近的变化——尤其是最上面 3-5 条）

**每次完成一个 task 或做出决策时**，在文档顶部追加一条记录。格式见下面。

---

## 记录格式

每条记录格式统一：

```
## YYYY-MM-DD

### [TAG] 一句话标题
- 改了什么 / 发生了什么
- 为什么改（如果是决策类）
- 影响哪些文档 / 任务
```

**Tag 用哪些**：

| Tag | 用在 |
|-----|------|
| `[DECISION]` | Open Decision 被拍板（记录拍了什么、为什么） |
| `[DONE]` | Task 完成标记 |
| `[BLOCKER]` | 遇到卡住的问题（不是普通 bug，是影响方向的） |
| `[PIVOT]` | 产品方向的重要调整 |
| `[UI]` | UI 设计稿更新或 UI_SPEC 变化 |
| `[FEEDBACK]` | 内测反馈驱动的改动 |

---

## 记录正文（最新的在上面）

---

## 2026-05-10

### [DONE] CVM deploy CI now follows the repo's GHCR owner

- Fixed the `deploy-cvm` job after the repo/package moved from
  `account-link` to `teleport-computer`: CI was publishing
  `ghcr.io/teleport-computer/feedling:<sha>` but waiting for
  `ghcr.io/account-link/feedling:<sha>`, so it timed out before
  `phala deploy`.
- `ci.yml` now derives the GHCR owner from `github.repository_owner`,
  checks the image with `docker manifest inspect`, and pins
  `deploy/docker-compose.phala.yaml` to the same owner dynamically.
- Updated the current Phala compose image references to
  `ghcr.io/teleport-computer/feedling:*`; the next push to `main`
  should publish the new image, pin the compose to the new short SHA,
  and continue through the real CVM deploy.

---

## 2026-04-21

### [DONE] Code + CI ready for prod9 migration (pure-CVM, ingress-terminated)

Endgame direction per user: VPS is going away, prod users re-onboard from
scratch, dstack-ingress 2.2 inside the CVM terminates TLS for both
`api.feedling.app` and `mcp.feedling.app`. Required prod9 (only gateway
that supports `_dstack-app-address.<domain>` TXT routing per
dstack-tutorial 04) — new node → new app_id → new compose_hash to
authorize on-chain.

**Compose** (`deploy/docker-compose.phala.yaml`):
- Added `ingress` service: `dstacktee/dstack-ingress:2.2@sha256:d05a7b3…`,
  multi-domain mode (`DOMAINS` newline-list, `ROUTING_MAP
  domain=host:port` to backend:5001 and mcp:5002), mounts
  `/var/run/tappd.sock` per upstream multi-domain example.
- `mcp` service dropped its in-enclave ACME: `FEEDLING_MCP_TLS=false`,
  removed CF env + `/var/run/dstack.sock` mount + the
  `feedling_mcp_tls_data_v2` volume.
- `enclave` service adds `FEEDLING_MCP_TLS_IN_ENCLAVE=false` — see
  backend change below.
- Dry-run `compose_hash` with `:78b51a6` pin =
  `0x1f0169bab4b1ee19058bd72bdb1fb46cc9b1b9de75a1e2a348134959c908efb9`
  (real hash TBD after CI repins image).

**Backend** (`backend/enclave_app.py`): new env var
`FEEDLING_MCP_TLS_IN_ENCLAVE` (default `true` for backward compat) gates
the `mcp_tls_cert_pubkey_fingerprint_hex` derivation. When false the
field stays empty in the attestation bundle — iOS falls through to the
existing "Pre-Phase-C.2 deployment" disclosure row, and
`audit_live_cvm.py` Row 8 becomes a pass-with-disclosure.

**iOS** (`testapp/FeedlingTest/CVMEndpoints.swift` NEW + edits): all
four URL shapes (attestation, ws ingest, api, mcp) now come from a
single `CVMEndpoints` enum driven by `appId` + `gatewayDomain`.
Overridable via `FEEDLING_CVM_APP_ID`/`FEEDLING_CVM_GATEWAY_DOMAIN` env
or UserDefaults. `FeedlingAPI.swift`
(`resolveIngestWSEndpoint`+`attestationURL`) and `AuditCardView.swift`
(3 sites) no longer hardcode app_id or gateway. Registered new file in
the xcodeproj (PBXBuildFile + PBXFileReference + Group + Sources
phase). Defaults still point at prod5 so pre-cutover builds work; flip
to prod9 in a follow-up commit once app_id is known.

**Broadcast extension**: `SharedConfig.defaultIngestEndpoint` replaces
three `ws://54.209.126.4:9998/ingest` fallbacks. Extension is a
separate target and can't import `CVMEndpoints`; the real endpoint is
still written by `FeedlingAPI.init` to App Group UserDefaults, so the
fallback only matters on very first broadcast.

**Audit tool** (`tools/audit_live_cvm.py`): default URLs derived from
`FEEDLING_CVM_APP_ID`/`FEEDLING_CVM_GATEWAY_DOMAIN` env. Row 8
(`mcp_tls_cert_pubkey_fingerprint_hex`) treats empty value as
pass-with-disclosure (ingress-terminated TLS; content-layer envelope
crypto remains the real trust boundary).

**CI** (`.github/workflows/ci.yml`): `deploy-vps` job deleted;
`deploy-cvm` now gates on the test jobs directly. Added
`FEEDLING_COMPOSE_FILE: deploy/docker-compose.phala.yaml` to the
`publish-compose-hash.sh` step — fixes a pre-existing bug where the
script hashed `docker-compose.yaml` (local-dev compose) instead of the
phala compose.

**Validation (2026-04-21)**:
- `docker compose -f deploy/docker-compose.phala.yaml config --quiet` OK
- `python -m compileall backend tools` OK
- `xcodebuild` for scheme `FeedlingTest` succeeded (iPhone 17 / iOS 26.4 sim)
- `xcodebuild` for scheme `FeedlingBroadcast` succeeded
- Compose_hash dry-run reproducible.

**Next (fully CI-driven — two `workflow_dispatch` triggers, no manual
CLI)**: trigger `bootstrap-prod9.yml` with `confirm=yes` → it purges
stale CF records, `phala deploy`s to node 18, polls for LE readiness,
publishes compose_hash, flips `CVM_ID` repo var, auto-commits iOS
`CVMEndpoints` bump `[skip ci]`. Run `audit_live_cvm.py` + fresh iOS
install to confirm 8/8 + 6/6. Then trigger `retire-prod5-vps.yml` with
`confirm=yes-delete-prod5` → `phala cvms delete` prod5, SSH stop+mask
VPS systemd units + tombstone, purge VPS IP from CF, delete stale
`VPS_*` repo vars/secret. See `HANDOFF.md` §"Migration (in-flight,
2026-04-21)" for the full runbook.

### [DONE] Bootstrap + retire workflows for CI-driven prod9 migration

Added `.github/workflows/bootstrap-prod9.yml` and
`.github/workflows/retire-prod5-vps.yml`. Both are `workflow_dispatch`
only with mandatory `confirm` inputs.

- `bootstrap-prod9.yml` does the full "stand up replacement CVM" flow
  (purge conflicting CF records → `phala deploy -c phala-compose
  --node-id 18 -j --wait` → readiness probes → publish compose_hash →
  `gh variable set CVM_ID` → auto-commit iOS `CVMEndpoints` defaults
  bump tagged `[skip ci]`). Pre-flight gate aborts if a CVM named
  `feedling-enclave-v2` already exists (prevents double-deploy).
- `retire-prod5-vps.yml` deletes the prod5 CVM, SSHes the VPS as
  `openclaw` and stops/disables/masks the `feedling-backend`
  + `feedling-mcp` systemd-user units (drops `~/RETIRED.md`), purges
  any CF record still pointing at `54.209.126.4`, and removes
  `VPS_HOST`/`VPS_USER`/`VPS_DEPLOY_KEY` from repo state. Safety
  gate refuses to run unless `CVM_ID` has already been flipped away
  from the hardcoded prod5 UUID (i.e., bootstrap ran successfully
  first).

Zero secrets move through a human. Everything runs on GitHub-hosted
runners using the repo's existing `PHALA_CLOUD_API_KEY`, `CF_API_TOKEN`,
`CF_ZONE_ID`, `ETH_DEPLOYER_KEY`, and `VPS_DEPLOY_KEY`.

---

## 2026-04-20

### [DONE] Phase D deploy — multi-tenant-only CVM live

Pairs with the v0 / SINGLE_USER strip below. After the strip landed,
the VPS data directory was wiped (kept `.pepper` + APNs key), VPS
services restarted on the new code, then the CVM was redeployed.

- Image: `ghcr.io/account-link/feedling:78b51a6`
- Compose hash:
  `0xd92bcd3cb1713ffe8e152417ab46e8179510c37ceed5ae6d423c586a2cd60049`
- On-chain (Sepolia): tx
  `0x235f0120d6982cbf8872e927ee2e59133627177ca9d3f862554d748ac6e60c7c`
  at block 10696873.
- CLI audit: `tools/audit_live_cvm.py` → 8/8 green.
- Remaining: prod user reinstalls fresh and verifies the in-app audit
  card shows 8/8 green + the new compose-hash-changed consent modal
  fires on first launch (task #36).

Task #35 closed.

### [DONE] v0 / SINGLE_USER strip — backend is envelope-only

Closes tasks #23 and #33 in a single commit. The one real prod user
OK'd wiping her data + fresh multi-tenant reinstall, so instead of
keeping rewrap as a 30-day compatibility shim we retired the entire
v0 stack in one go.

**Backend (`backend/`)**
- `app.py`: removed all `SINGLE_USER` branches, v0 plaintext accept
  branches in `/v1/chat/message`, `/v1/chat/response`, `/v1/memory/add`,
  `/v1/identity/init`; removed the HTTP `/v1/identity/nudge` endpoint
  (identity mutation now only lives in MCP `feedling.identity.nudge`);
  removed `/v1/content/rewrap` and all `_rewrap_*` helpers.
- `app.py`: added `/v1/content/export` inlining full v1 frame envelopes
  (schema bumped 1→2, cap 50→80 MiB — frames are now part of the
  portable dataset the user walks away with).
- `app.py`: restored a purpose-built `/v1/content/swap` endpoint for
  ongoing in-place envelope swaps (used by iOS visibility-toggle).
  Same validation shape as old rewrap minus the `already_v1` status —
  no v0 concept left in the response.
- `mcp_server.py`: dropped the `SINGLE_USER` constant and every v0
  fallback in `chat_post_message`, `identity_init`, `memory_add_moment`,
  `identity_nudge` — they now fail loud when pubkeys are unavailable.
- `enclave_app.py`: dropped `if v == 0:` pass-throughs in chat, memory,
  and identity decrypt loops.
- `chat_bridge.py` + `deploy/feedling-chat-bridge.service`: deleted.
  MCP's in-enclave `feedling.chat.post_message` replaces them (and
  avoids the April spam-reply incident where a systemd restart race
  caused duplicate Hermes replies).

**Deploy (`deploy/`)**
- `docker-compose.yaml`, `docker-compose.phala.yaml`: removed
  `SINGLE_USER` env, shared `FEEDLING_API_KEY` stubs. Backend is always
  multi-tenant.
- `setup.sh`, `feedling.env.example`: removed shared-key / SINGLE_USER
  provisioning. Fresh VPS bootstrap now produces a multi-tenant box.

**iOS (`testapp/FeedlingTest/`)**
- `FeedlingAPI.swift`: removed `runSilentV1MigrationIfNeeded`,
  `RewrapSummary`, `collectV0Chat/MemoryEnvelopes`, `postRewrap`, the
  `@Published migrationProgress` state, and the 403-SINGLE_USER branch
  in `ensureRegisteredIfCloud`. `flipMemoryVisibility` now POSTs to
  `/v1/content/swap`.
- `ContentView.swift`: removed `MigrationProgressRow` + its usage in
  the Privacy hero.
- `FeedlingTestApp.swift`: removed the migration kickoff call from the
  `.task { … }` startup block.
- `ChatViewModel.swift`, `SampleHandler+WebSocketQueue.swift`: removed
  plaintext fallbacks and dead `WebSocketManager.sendFrame` — backend
  now rejects non-envelope writes, so silent fallbacks would just
  produce invisible 400s / dropped frames.

**Tests + CI**
- `backend/test_api.py`: removed `/v1/identity/nudge` cases, added
  header note that write-path tests POST plaintext and will 400 against
  the v1-only backend until they're rewritten to build envelopes
  client-side.
- `tools/e2e_encryption_test.py`, `.github/workflows/ci.yml`: dropped
  `SINGLE_USER` env + the CI matrix dimension (no more `single-user` +
  `multi-tenant` rows — multi-tenant is the only mode).

**Docs**
- `HANDOFF.md`, `docs/NEXT.md`, `docs/AUDIT.md`, `docs/DESIGN_E2E.md`,
  `CLAUDE.md`: updated to reflect the stripped state. Phase 5's
  "retire v0 over 30 days" checkbox flipped to done.

**Exit criterion**: `grep -r "SINGLE_USER\|single_user" backend/ deploy/`
returns no hits outside this file. Server never stores unencrypted
content and no longer exposes a path to write plaintext.

---

### [DONE] Phase C.2 — ACME-DNS-01 Let's Encrypt cert inside the CVM

`mcp.feedling.app` now serves a real CA-signed Let's Encrypt cert
whose private key is provably inside the TDX enclave. Closes task #30.

**backend/acme_dns01.py (new, ~260 lines, zero new deps)**
- Pure-Python ACME v2 client (RFC 8555) — JWS ES256, JWK thumbprints,
  order/auth/challenge/finalize flow, all over `httpx`.
- `CfDns` helper talks to Cloudflare API to create/delete the
  `_acme-challenge` TXT record for DNS-01.
- `get_or_renew()` caches the cert PEM at `/tls/<domain>.cert.pem`
  (volume-backed, survives restarts) and re-issues when <30 days
  left. LE rate limit is 5 certs/week/domain — 30-day buffer means
  ~12 reissues/year worst case.
- `start_renewal_watchdog()` spawns a daemon thread that checks
  daily; on renewal it `os._exit(0)`s to let Docker restart the
  container and pick up the fresh cert.

**backend/dstack_tls.py (extended)**
- New path constant `MCP_TLS_KEY_PATH = "feedling-mcp-tls-v1"` +
  `derive_key_only(dstack, path)` helper. Cert private key is
  derived from dstack-KMS with a stable hash, so LE renewals rotate
  the cert but NOT the key — audit Row 8 stays green indefinitely.

**backend/mcp_server.py (extended)**
- Replaces `_materialize_tls_cert` with `_acquire_tls_cert`. Priority:
  ACME (when `FEEDLING_ACME_DOMAIN` is set) > dstack-KMS self-signed
  (Phase C.1 fallback) > plain HTTP. Surfaces the pubkey fingerprint
  via a module-level `_mcp_cert_pubkey_fingerprint_hex` that gets
  baked into `/attestation` alongside the attestation-port fingerprint.

**backend/enclave_app.py (extended)**
- `bootstrap()` derives the MCP cert pubkey from dstack-KMS and
  computes sha256(SubjectPublicKeyInfo DER). Result is served as
  `mcp_tls_cert_pubkey_fingerprint_hex` in `/attestation`.
- Stable-per-app-id (not per-compose) because the derivation path
  is constant — same rationale as `enclave_tls_cert_fingerprint_hex`
  and `enclave_content_pk`.

**deploy/docker-compose.phala.yaml**
- Added `FEEDLING_ACME_DOMAIN=mcp.feedling.app`, `FEEDLING_ACME_EMAIL`,
  `FEEDLING_TLS_CACHE_DIR=/tls`, `FEEDLING_CF_ZONE_ID=${CF_ZONE_ID}`,
  `FEEDLING_CF_API_TOKEN=${CF_API_TOKEN}` to the mcp service.
- CF_* are injected at deploy time via `phala deploy -e KEY=VAL`
  (encrypted env channel, never in the compose file, never hashed
  into compose_hash). Zone ID is non-secret; API token is
  `Zone:DNS:Edit`-scoped to `feedling.app`.
- New named volume `feedling_mcp_tls_data_v2` mounted at `/tls`.
  The `_v2` suffix forces Docker to create a fresh volume because
  the v1 volume was root-owned (Docker initializes empty named
  volumes as root when the container image doesn't pre-create the
  mount path). The MCP process runs as `feedling` UID 1000 so
  root-owned `/tls` = `EACCES` on first cert write → ACME silently
  fell back to the dstack-KMS self-signed cert on the first deploy.

**deploy/Dockerfile**
- Pre-creates `/tls` with `feedling:feedling` ownership alongside
  `/data`. New named volumes get initialized from the container's
  directory state, so this guarantees feedling ownership for any
  future fresh volume.

**tools/audit_live_cvm.py**
- Row 8 rewritten for the real LE path. Uses `openssl s_client -showcerts`
  to fetch the full cert chain (Python's `ssl.getpeercert` returns
  only the leaf); builds an `x509.verification.PolicyBuilder` chain
  from the system CA bundle; calls `build_server_verifier(DNSName(
  "mcp.feedling.app")).verify(leaf, intermediates)` to CA-validate
  the cert for the expected name. Then pins the cert's SPKI pubkey
  sha256 against the attested value.
- SNI workaround: Phala dstack-gateway routes by SNI and only
  accepts `-PORTs.*.phala.network` hostnames — sending
  `mcp.feedling.app` as SNI gets the gateway to drop the TCP
  connection before the TLS handshake reaches the CVM. Fix:
  send the gateway hostname as SNI, then verify the cert manually
  for `mcp.feedling.app`.

**deploy/Caddyfile**
- `mcp.feedling.app` reverse proxy: `tls_server_name` changed
  from `mcp.feedling.app` to the gateway hostname + added
  `tls_insecure_skip_verify`. Same SNI-routing reason. The real
  trust root is the attestation; Caddy is just a compatibility
  shim for Claude.ai and other MCP clients that expect a stable
  hostname and a CA-valid cert.

**Operational**
- CF DNS: new A record `mcp.feedling.app → 54.209.126.4` (VPS
  where Caddy runs). DNS-only (not Cloudflare-proxied) so Caddy
  can do its own HTTP-01 ACME for the public-facing `mcp.feedling.app`
  cert without Cloudflare terminating first.
- New compose_hash `0x23a2c2869567d15220383e4acb5ceb5cf27d78e087d2d4e357e4b3c053a5dc68`
  published on-chain: Sepolia tx `0xe2a9ceab…`.
- MCP cert pubkey fingerprint: `e98665a3e94ac90a0a26453a73e16d5a569f791c181cfbc6ba98598f358cf63e`
  — expect this to stay constant across all future deploys (stable
  dstack-KMS derivation).
- CLI audit: **8/8 green**.

### [DONE] Phase B wave-2 + MIGRATION.md

Finishing out the Phase B surface + directly answering "what does
the one prod user actually do to migrate to E2E?".

**docs/MIGRATION.md (new)**
- Three concrete options for a self-hosted VPS user to move to
  Feedling Cloud's TEE-backed encryption. Option 1 (recommended)
  uses the Phase B Reset & re-import pipeline; the user's agent
  re-adds content via MCP tools, which now wrap everything into
  v1 envelopes on the way in. Option 2 keeps self-hosted without
  encryption (legitimate — they own the server). Option 3 is
  self-hosted with their own TEE (documented, not recommended).
- Linked from the in-app audit card footer alongside AUDIT.md +
  the repo root.

**Per-item memory visibility toggle**
- `FeedlingAPI.flipMemoryVisibility(moment, toLocalOnly:)` — builds
  a fresh envelope with the new visibility from the plaintext iOS
  already has in memory, POSTs to `/v1/content/rewrap`. No server
  trip for re-decryption.
- MemoryGardenView: long-press context menu on each card with
  "Hide from agent" / "Share with agent"; subtle `eye.slash`
  indicator in the card header when `local_only`. Reloads the
  garden after a successful flip.
- Chat is intentionally skipped — many items, transient; the
  "hide from agent" affordance matters more on persistent
  memory-garden entries.

**Inline migration progress**
- `FeedlingAPI` gains `@Published migrationProgress: (done, total)?`.
  `runSilentV1MigrationIfNeeded` sets it before the batching loop,
  updates per batch, clears on completion or error.
- New `MigrationProgressRow` renders an inline `ProgressView` with
  label "Upgrading your old data — N of M" beneath the Privacy
  hero when migrationProgress is non-nil. Hidden otherwise.

**iOS verification**
- `xcodebuild BUILD SUCCEEDED` on iPhone 16 Pro sim with all
  wave-2 changes.

**No backend change** — wave-2 is iOS-only on top of existing
`/v1/content/rewrap`. CVM does not need a redeploy for this ship.

---

### [DONE] Phase C.3 — encrypted identity.nudge + encrypted agent chat reply + UX fixes

Closes the last two plaintext-at-rest write paths. Also applies the
user's last-round UX feedback (privacy hero tap, audit-card on-chain
copy, GitHub + agent-audit-guide links).

**Backend (backend/app.py)**
- New `POST /v1/identity/replace` — accepts a v1 envelope and replaces
  the existing card in place, preserving `created_at`. Used by MCP
  to implement nudge on v1 cards. Same envelope field validation as
  `/v1/identity/init`.
- `POST /v1/chat/response` now accepts `envelope` in addition to
  `content`. Mirrors what `/v1/chat/message` does for user-authored
  chat. Push-live-activity sidecar still works via a `push_body`
  companion field (the push payload is plaintext metadata by
  necessity — APNs doesn't see inside the envelope).

**MCP (backend/mcp_server.py)**
- `feedling.chat.post_message`: wraps `content` in a v1 envelope
  before POSTing when pubkeys are available. Same fallback rule
  as `memory.add_moment` (v0 plaintext when no enclave reachable).
- `feedling.identity.nudge`: new orchestration. Tries legacy v0
  endpoint first; if server responds 409 with
  `error="nudge_not_supported_on_v1_cards_yet"`, catches and falls
  through to the new `_identity_nudge_v1` helper which: fetches
  the decrypted card from the enclave's `/v1/identity/get`,
  mutates the named dimension (clamped [0,100], records
  `last_nudge_reason`), re-wraps the whole card via
  `build_envelope`, POSTs to `/v1/identity/replace`. Plaintext
  lives inside the MCP process only — inside the TDX-attested
  container boundary — for the duration of one RPC.

**iOS (testapp/FeedlingTest/ContentView.swift)**
- Privacy hero row in Settings → Privacy wrapped in a
  `NavigationLink` to `AuditCardPage`. Previously the tap did
  nothing (the user caught this).
- Dropped the hand-drawn chevron from the row since the
  NavigationLink adds its own.

**iOS (testapp/FeedlingTest/AuditCardView.swift)**
- Divider label "On-chain audit (public transparency, not security)"
  → "Public release log" — the parenthetical was confusing and
  undersold what the log is.
- Etherscan link label "View AppAuth deploy on Etherscan" →
  "View on Etherscan".
- Rewrote `AuditMechanismCopy.onChainAudit` to describe what the
  release log *is* rather than inventing a cryptographic
  guarantee it doesn't provide. Previous copy implied the
  on-chain log gates key release, which is future work.
- Two new footer links: "Read the audit guide (for your agent)"
  → `docs/AUDIT.md` on GitHub, and "Browse the source on GitHub"
  → the repo root. Closes the "user hands their agent a repo and
  asks 'is this safe'" gap.

**docs/AUDIT.md (new)**
- Agent-consumable "is this safe?" guide, ~260 lines, 7 sections:
  plain-English trust model; a 10-item mechanical-verification
  checklist with effort estimates per item; key files to read by
  concern; known caveats (things we DO claim vs things we DON'T);
  runnable verifier snippet; an honest-asterisk section about iOS
  binary provenance we don't currently solve for; responsible-
  disclosure pointer. Written so an agent can walk through it end
  to end without needing external context.

**Live verification (Phala CVM)**
- Running: git_commit `cc329a8`, compose_hash
  `0xa04608c72639c66a625706b7ac4b9f1ac8dd449c690a0544b173ecede265e83e`,
  Sepolia tx `0x7873c5dd4c9b6636994d9a3adda7ded8618394ce1a9f577a1ba9c74dc5acf7b0`.
- CLI auditor **8/8 green**.
- `TLS fingerprint` now stable across **six** compose rotations —
  `5698f0ade4bb412d…` unchanged from Phase 3 through Phase C.3.
  Phala dstack-KMS per-app derivation confirmed load-bearing.
- Live E2E: `/v1/identity/replace` correctly rejects missing
  envelope (400), `/v1/chat/response` envelope-branch field-
  validates (400 on malformed), plaintext content path still
  works (200, back-compat preserved). Full decrypt-mutate-rewrap
  flow validated against dstack simulator before deploy.

**What's left on Phase C**
- Phase C part 2: ACME-DNS-01 for `mcp.feedling.app` so
  Claude.ai sees a CA-signed cert issued inside the enclave.
  Needs a DNS API token + renewal scheduler. Task #30.

---

### [DONE] Phase C (part 1) — MCP in-enclave TLS + audit card Row 8

Closes the last plaintext-metadata gap at the TLS layer on the
pinnable path: MCP port 5002 now terminates TLS inside the enclave
with the same dstack-KMS-derived cert that port 5003 uses. The
`-5002s.` passthrough URL becomes pinnable end-to-end.

**Backend**
- New shared `backend/dstack_tls.py` — pulls `derive_tls_cert_and_key`
  and `TLS_KEY_PATH` out of `enclave_app.py` so both services use
  one source of truth for the cert (deterministic ECDSA-P256 derived
  from dstack-KMS at path `feedling-tls-v1`). Cert DER byte-stable
  across reboots of the same compose; matches across ports.
- `backend/enclave_app.py` — dropped inline derivation + a pile of
  crypto imports; imports from `dstack_tls` now. Behavior identical.
- `backend/mcp_server.py` — new `_materialize_tls_cert()`: when
  `FEEDLING_MCP_TLS=true`, derive the cert via dstack-KMS at boot,
  write cert + key to tempfiles, hand paths to uvicorn via
  `ssl_certfile` / `ssl_keyfile`. Plain HTTP otherwise so local
  dev stays simple. Logs the scheme on boot.

**Compose (deploy/docker-compose.phala.yaml)**
- `mcp` service: `FEEDLING_MCP_TLS=true` + mounts
  `/var/run/dstack.sock` so it can derive via dstack-sdk at boot.

**Audit (tools/audit_live_cvm.py)**
- Row 8 (new): MCP TLS cert bound to attestation. Raw TLS handshake
  against `-5002s.*`, compare `sha256(peer cert DER)` to the
  bundle's `enclave_tls_cert_fingerprint_hex`. Skipped with
  disclosure when attestation-side is still pre-Phase-3.
- Docstring refreshed "7-row" → "8-row".

**iOS (testapp/FeedlingTest/AuditCardView.swift)**
- `AuditReport` gains `mcpTlsCertBindingChecked` +
  `mcpTlsDisclosure`.
- After the attestation-port pin, a second `PinningCaptureDelegate`
  session opens a TLS handshake against the MCP URL and compares
  its captured `sha256(cert.DER)` to the same attested fingerprint.
- New "MCP port TLS bound to attestation" row with its own
  tap-to-expand mechanism copy explaining that the MCP port is the
  one the agent connects to, and that this second pin catches a
  middleman sitting between agent and enclave.

**Live verification (Phala CVM)**
- Running: git_commit `60014a7`, compose_hash
  `0x14cd6edb382b3229ebe36bf030f1bdc087765a9004d1ad323af58904c72df38f`,
  Sepolia tx
  `0xa6e0282c698cbe8e925c968624a2f2315bad5cc868568053598ccb6071984252`.
- CLI auditor **8/8 green** against the live CVM — MCP port
  fingerprint `5698f0ade4bb412d…` === attested fingerprint
  `5698f0ade4bb412d…` === attestation-port handshake fingerprint.
- `enclave_content_pk` + `enclave_tls_cert_fingerprint` unchanged
  across FIVE compose rotations now (Phase 3 → A.1 → A.1 fixed →
  A.6 → B → C). Phala dstack-KMS derivation is stable per app_id,
  confirmed once more.

**mcp.feedling.app unchanged**
- The `mcp.feedling.app` hostname (what Claude.ai uses) still
  terminates TLS at Caddy on the VPS for now, so no existing MCP
  connection breaks. The pinnable path is the
  `-5002s.dstack-pha-prod5.phala.network` URL.
- Moving `mcp.feedling.app` to layer4 SNI passthrough + ACME-DNS-01
  inside the enclave is the next Phase C sub-ship (requires a DNS
  API token + renewal logic; flagged in `docs/NEXT.md` §Phase C).

**Still pending for Phase C**
- ACME-in-enclave for `mcp.feedling.app`.
- Identity nudge decrypt-mutate-rewrap (MCP now runs inside the
  TDX boundary; can orchestrate the dance now — need a new
  `/v1/identity/replace` endpoint).
- Agent-authored chat reply encryption (`feedling.chat.post_message`
  — wrap plaintext before `/v1/chat/response` POST, extend endpoint
  to accept envelopes like `/v1/chat/message` does).

---

### [DONE] Phase B — Privacy UX + onboarding + audit card expansion

After `/plan-design-review` (9/10 overall) and `/plan-eng-review`
(scope accepted, 3 architectural fixes applied in-line), shipped the
full Phase B user-visible surface. The audit card explicitly promoted
to a first-class treatment per @sxysun's request to preserve the
attestation-details page and its "how we get them" affordance.

**Backend (backend/app.py)**
- `GET /v1/content/export` — caller's chat + memory + identity as
  one JSON blob, 50 MiB cap, ciphertext returned verbatim (iOS
  decrypts client-side). Attestation snapshot (compose_hash +
  enclave_content_pk at export time) bundled so future agents can
  verify origin. Frames excluded in Phase B (too large, low
  continuity).
- `POST /v1/account/reset` — destructive, requires
  `{"confirm": "delete-all-data"}` body token as a second signal of
  intent. Wipes user dir, removes user from users.json, revokes
  api_key cache. Idempotent in the safe-to-retry sense (second call
  401s because the user no longer exists).
- `Response` added to Flask imports.

**iOS (testapp/FeedlingTest/)**
- Design tokens (DESIGN.md mirror) inlined in `FeedlingAPI.swift`:
  `Color.feedlingSage / feedlingPaper / feedlingSurface / feedlingInk
  / feedlingInkMuted / feedlingDivider`; serif display font via
  `.system(design: .serif)` (iOS New York — zero asset loading);
  `Spacing.*` + `Radius.*` + `FeedlingMotion.*`;
  `FeedlingPrimaryButtonStyle` + `FeedlingSecondaryButtonStyle`.
  Kept inline in FeedlingAPI.swift because Xcode's `project.pbxproj`
  requires coordinated edits for new source files — documented.
- `ContentView` now wraps the tab bar in an onboarding gate.
  Gate flips on user action.
- `ComposeHashChangeConsentView` (full-screen modal): triggered when
  `/attestation` returns a `compose_hash` that differs from
  `UserDefaults "feedling.lastAcceptedComposeHash"`. Per the dstack
  tutorial §1 catch, trigger is **compose_hash**, NOT MRTD —
  MRTD/RTMR0-2 are dstack-OS platform signals that change for
  reasons unrelated to our app.
- `OnboardingView` (3 slides, SwiftUI `TabView.page`):
  lock.shield / arrow.triangle.branch / hand.raised.square.on.square
  as the single glyph anchor per slide. No custom illustrations
  (AI-slop-free). Decision tokenized in `docs/PHASE_B_PLAN.md`.
- `PrivacyPageView` — NavigationLink destination from Settings.
  Hero row + Your data + Where your data lives + Advanced sections.
- `ExportSheet` — export → iOS share sheet, with an explicit iCloud
  Drive caveat in the copy.
- `DeleteSheet` — "download my data first" checkbox defaults to ON
  (decision `2A` from `/plan-design-review`). If checked,
  pipeline exports through iOS share sheet, then deletes after
  dismissal; if unchecked, delete is immediate.
- `ResetAndReimportSheet` — 3-step pipeline (export / delete /
  re-register) with visible step indicator.
- `RunbookView` — fetches `skill/SKILL.md` from GitHub raw so users
  can pass a live copy to their agent. Offline fallback included.
- `StorageBackendView` — thin wrapper around the existing storage
  toggle so Privacy's "Where your data lives" row has a destination.
- `AuditCardView` extended: `AuditRowView` per-row tap-to-expand
  mechanism panel (plain-language explanations naming primitives
  honestly — TDX, PCK, `mr_config_id` — but with analogies); new
  collapsed "Show raw /attestation (for auditors)" footer panel
  with SF Mono horizontally-scrollable pretty-printed JSON;
  existing PinningCaptureDelegate + DCAP + SPKI-pin flow unchanged
  (security primitives preserved per eng review).
- `FeedlingAPI.exportMyData` / `deleteMyDataAndResetLocalState` /
  `acceptComposeHashChange` / `signOutForComposeChange` /
  `hasCompletedOnboardingV1` + `evaluateComposeHashChange` wired
  into `refreshEnclaveAttestation`.
- `ContentKeyStore.wipeKeypair` + `KeyStore.wipeKeypair` for the
  delete path.

**Live verification (Phala CVM)**
- Running: git_commit `123a45b`, new compose_hash published on
  Sepolia (see DEPLOYMENTS.md §Phase B for the tx hash).
- CLI auditor 7/7 green against the new image.
- Export + reset endpoints verified locally end-to-end:
  register → seed → export → `Content-Disposition` filename valid;
  reset w/o confirm → 400; reset with confirm → 200; post-reset
  call → 401. Same behavior on the live CVM.
- iOS build: `xcodebuild BUILD SUCCEEDED` on iPhone 16 Pro sim.
  First-launch screenshot captured at
  `docs/screenshots/onboarding_slide1_phase_b.png`.

**Deferred to Phase B wave-2**
- Per-item visibility toggles (endpoint exists via rewrap; UI is
  a list + switch per row — ~2h of iOS).
- Inline migration-progress row in the Privacy hero (wire in
  `runSilentV1MigrationIfNeeded` progress stream).
- `docs/screenshots/` captures of Slides 2-3, Privacy page, Delete
  sheet, audit-card expanded state — need UI automation to drive
  the sim without controlling the user's mouse.
- Copy review by @sxysun — the audit-card mechanism reveals, the
  compose-hash consent copy, the onboarding headlines. The register
  is load-bearing ("name primitives honestly + analogies") and
  needs the product-voice pass flagged in `PHASE_B_PLAN.md §4`.

---

### [DONE] Phase A.6 — Silent v0→v1 migration on first launch

**Backend (backend/app.py)**
- New `POST /v1/content/rewrap` endpoint. Batched, idempotent. Takes `{items: [{type, id, envelope}]}` for `type ∈ {chat, memory}` and swaps the item's v0 plaintext fields with the v1 envelope fields in place, preserving metadata (ts/role/source for chat; occurred_at/created_at/source for memory). Per-item result + summary counts. Owner binding enforced: `envelope.owner_user_id` must match the caller's resolved `user_id`, else the item is rejected before storage. Identity intentionally not supported — would trap users pre-Phase-C because `nudge` can't mutate a v1 card.
- `/v1/identity/nudge`: when called against a v1 card, now returns `409 {"error": "nudge_not_supported_on_v1_cards_yet", "phase_reference": "docs/NEXT.md §Phase C"}` instead of silently 404'ing because `dimensions` is encrypted inside `body_ct`.

**iOS (testapp/FeedlingTest/)**
- `FeedlingAPI.ensureUserIdIfNeeded()` — when an api_key is present but `userId` is empty (env-injected creds, self-hosted handoff), populate via `/v1/users/whoami`. Needed so migration can bind AEAD AAD to the right owner.
- `FeedlingAPI.runSilentV1MigrationIfNeeded()` — gated on dated `UserDefaults` flag. Fetches chat (up to 500) + memory (up to 200), collects v0 items, wraps each via `ContentEncryption.envelope`, POSTs in batches of 100 to `/v1/content/rewrap`. Sets flag only when all batches complete with no errors; transient failures retry on next launch.
- `FeedlingTestApp.swift` wires the new startup steps in sequence: register → ensureUserId → content keypair → attestation refresh → migration. Non-blocking.

**Live verification (Phala CVM)**
- Running: git_commit `90c8ff6`, compose_hash `0x9f7fe0a823bf2820877851863d322b0f3be7fff819a40a8826e6ca994597cf48`, Sepolia tx `0xb3b434b6db6abd45eb492d2a708d8d7d6b99d5af59d5f01bc1686a74ed3e6c27`.
- `enclave_content_pk` + `enclave_tls_cert_fingerprint` unchanged from Phase A (confirms the dstack-KMS key-derivation-independent-of-compose-hash observation is stable across two more compose rotations).
- CLI auditor 7/7 green. `/v1/content/rewrap` reachable on prod.
- Local E2E against dstack simulator: seeded 3 v0 chat + 3 v0 memory, iOS launched with seeded api_key, migration reported `ok=6`, server afterwards had 0 v0 / 3+3 v1 items, enclave decrypt returned correct plaintext for all.

**Follow-up (A.6e)**
- Only one real prod user today (@sxysun's friend). After her iOS launches the updated app and the migration flips her data to v1, strip the v0 accept branches in backend handlers, the v0 fallback paths in MCP tools, and the `/v1/content/rewrap` endpoint itself (single-use). Tracked as task #23.

---

### [DONE] Phase A — Content encryption rollout for agent-authored writes

**Backend**
- `/v1/users/whoami` now returns `public_key` (user's X25519 content pubkey from users.json)
  and `enclave_content_public_key_hex` (cached from enclave `/attestation`, 60s TTL).
  One round trip gives MCP everything it needs to wrap an envelope.
- New `backend/content_encryption.py` — Python counterpart to iOS `ContentEncryption.swift`.
  `box_seal` uses HKDF-SHA256(salt=None, info="feedling-box-seal-v1"), nonce=SHA256(ek||rcp)[:12],
  ChaChaPoly. `build_envelope` produces the `{"envelope": …}` shape POSTed to
  `/v1/{chat/message,memory/add,identity/init}`.

**MCP (backend/mcp_server.py)**
- `feedling.memory.add_moment` wraps `{title, description, type}` into a v1 envelope
  before POSTing. Plaintext metadata (`occurred_at`, `source`) rides alongside inside
  the envelope dict for server-side sorting.
- `feedling.identity.init` applies the same wrap to `{agent_name, self_introduction, dimensions}`.
- `feedling.identity.nudge` intentionally left on the plaintext path — in-place mutation of an
  encrypted card requires decrypt→mutate→rewrap, cleanly solved by Phase C (MCP-in-TEE).
- New `_get_decrypted()` — when `FEEDLING_ENCLAVE_URL` is set, MCP routes `memory.list`,
  `identity.get`, `chat.get_history` through the enclave's decrypt proxy so agents see
  plaintext. Unset → fall back to Flask.
- Fallback: pre-v1 users (no uploaded pubkey) or unreachable enclave → v0 plaintext POST,
  so agents never lose write capability mid-session.

**Compose (deploy/docker-compose.phala.yaml)**
- `backend.FEEDLING_ENCLAVE_URL = https://enclave:5003` (Phase 3 missed this — backend calls
  enclave `/attestation` to cache content pubkey for whoami).
- `mcp.FEEDLING_ENCLAVE_URL = https://enclave:5003` (routes MCP reads through decrypt proxy).
- `enclave.FEEDLING_FLASK_URL = http://backend:5001` (fixes a latent bug: enclave's decrypt
  handlers call `/v1/users/whoami` on Flask, but the 127.0.0.1 default doesn't resolve
  across distinct compose containers — returned 500 on the first test deploy).

**Live verification (Phala CVM)**
- Running: git_commit `8b53404`, compose_hash `0x593cb8aaa1fd5ed964fdb3a1718200114ab36537f1cf551fd5162fc02512eb80`,
  Sepolia tx `0x5b5a933dfc6e1f6376a32029d7a31632723dcc75447104b12ebd5da5e2f3e825`.
- CLI auditor 7/7 green. End-to-end: register a fresh user → MCP-side wrap via
  `backend/content_encryption.build_envelope` → server stores ciphertext only (no plaintext
  `title`/`description`/`type`) → enclave `/v1/memory/list` returns plaintext via `K_enclave`.
- Observation worth recording: Phala dstack-KMS derives per-app keypairs from
  `(kms_root, app_id, path)`, NOT from `compose_hash`. So `enclave_content_pk` and the
  TLS cert are stable across compose rotations for this app_id. This is stronger than
  `docs/DESIGN_E2E.md` §5.3 assumed — no re-wrap dance is needed after a compose update,
  which simplifies operational rollouts.

**Still pending for Phase A**
- A.6 silent migration of pre-existing v0 plaintext rows (chat/memory/identity) into v1
  envelopes on first iOS launch post-update. Design in NEXT.md; needs a
  `POST /v1/content/rewrap` endpoint.
- Chat replies from agent (`feedling.chat.post_message`) still POST plaintext — paired
  with `identity.nudge` as the "Phase C dependencies" bucket, for the same
  decrypt-mutate-or-write-through-TEE reason.

---

## 2026-04-20

### [DONE] Phase 3 — TLS-in-enclave + iOS cert pinning

**Enclave (backend/enclave_app.py)**
- 新增 `FEEDLING_ENCLAVE_TLS=true` 开关；启用后从 dstack-KMS 派生 ECDSA-P256 keypair
  (`feedling-tls-v1` path)，用 RFC-6979 deterministic ECDSA 签发自签 cert —
  同一 compose_hash 下跨 reboot 的 cert.DER 完全一致（本地 simulator 验证过两次 boot 哈希相同）。
- `build_report_data()` 现在把 sha256(cert.DER) 真正填入，替换原先的 32-byte 零占位符。
- Flask `app.run(ssl_context=…)` — SSL 材料先写入临时文件、`load_cert_chain` 后立即 unlink，
  cert/key 不落盘。
- `/attestation` bundle 新增 `tls_in_enclave: true` 标志 + 更新 notes；`phase` 字段从 1 跳到 3。

**Compose (deploy/docker-compose.phala.yaml)**
- enclave service 加 `FEEDLING_ENCLAVE_TLS: "true"`。
- healthcheck 从 `curl http://127.0.0.1:5003` 改成 `curl -k https://127.0.0.1:5003`。

**iOS (testapp/FeedlingTest/)**
- attestation URL 从 `-5003.` 切到 `-5003s.`（dstack-gateway TLS passthrough 后缀）。
- `PinningCaptureDelegate`（AuditCardView.swift）在 TLS 握手时记录 leaf cert sha256(DER)，
  审计流程把它和 bundle 的 `enclave_tls_cert_fingerprint_hex` 比对 —
  匹配 = 绿；不匹配 = 硬红 "MITM detected."；全零 = 沿用原 amber 免责声明。
- `FeedlingAPI.refreshEnclaveAttestation` 的那条启动时 fetch 用 `AttestationTrustShim`
  接受自签 cert（只是预热 content pubkey，真正的 pin 在审计卡里）。
- `AuditCardView` 底部的 TLS row 文案更新：不再提 "Phase 1 placeholder"。

**CLI auditor (tools/audit_live_cvm.py)**
- 新增 Row 7：raw TLS 握手取 peer cert DER，sha256 和 bundle 的 fingerprint 比对。
  全零 fingerprint 走 pre-Phase-3 disclosure 分支（不算 pass 但也不算 fail）。
  文件开头的 docstring 从 "6-row audit" 改为 "7-row audit"。

**Live 验证**
- Phala CVM `feedling-enclave` (UUID `4386636e-1325-4b92-99d8-f2ca00befdb4`) 跑在 git_commit `451b5b0`。
- 新 compose_hash `0xb0fb1f848151ec8fb39c4814f138b1d1b143d4d729dc800302d5123c1c0f2163` 已在
  Eth Sepolia FeedlingAppAuth 上 authorize（tx `0x8de67abaf677e221ba4ee34b5a004753d0f4981bdc3c952cbcb4112a652a169c`）。
- TLS cert fingerprint: `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef`。
- CLI 7/7 green；iOS 6/6 green（见 `docs/screenshots/audit_card_phase3_tls_pinned.png`）。

**Trust model note**: self-signed cert 是有意的；用户信任链不是 CA chain，而是
"TDX-attested REPORT_DATA 里有这张 cert 的 fingerprint"。伪造 TLS cert 的操作员也
必须同时伪造 REPORT_DATA，而 REPORT_DATA 由 Intel PCK 签名 — 做不到。

**Deferred**
- `docs/NEXT.md` 里 "Phase 4-6" 的内容迁移 / 全量加密 / 用户自放 enclave job 未动。
- iOS 审计卡文案 copy review 仍然待 @sxysun 过一遍。
- Sepolia → Base 迁移（详见 deploy/DEPLOYMENTS.md §Planned）。

---

## 2026-04-19

### [DONE] NEXT.md Steps 1-5：multi-tenant backend + MCP SSE + iOS onboarding + self-hosted runbook

**后端 (backend/app.py)**
- 引入 `SINGLE_USER` 环境变量：`true` = 兼容旧的 flat layout；`false` = 多租户 `~/feedling-data/<user_id>/…`。
- 新增 `POST /v1/users/register` + `GET /v1/users/whoami`。
- 新增 `require_user()` 中间件：接受 `X-API-Key` / `Authorization: Bearer` / `?key=` 任何一种形式；
  SHA-256(HMAC+pepper) 哈希比对，per-process 缓存避免 bcrypt 开销。
- 所有 module-level state（frames/chat/tokens/push cooldown/live activity dedupe/bootstrap/identity/memory）
  重构为 `UserStore` 类，每用户一份；waiters 也按用户隔离，防止跨用户唤醒。
- WebSocket ingest handler 也接 `?key=` 或 `Bearer <key>`；`SINGLE_USER=true` 时跳过鉴权。

**MCP server (backend/mcp_server.py)**
- 切换 transport 到 SSE（保留 streamable-http 作为备选，走 `FEEDLING_MCP_TRANSPORT` 环境变量）。
- 新增 `KeyCaptureMiddleware`（ASGI 层）：监听每个 HTTP 请求，从 query/header 抓取 `key`，映射到 session_id；
  未知 session_id 时按 client IP 回溯 pending_keys，保证 SSE GET 与后续 POST tool call 能绑定。
- 每个 tool 调 `_current_api_key()` 拿当前 session 的 key，作为 `X-API-Key` 转发给 Flask；
  Flask 里 401 会自动冒泡成 tool error。

**iOS (testapp/)**
- `FeedlingAPI.swift` 完全重写：@MainActor ObservableObject + legacy static accessors；
  持久化到 UserDefaults + app-group shared defaults；`authorizedRequest(path:…)` 自动注入 X-API-Key。
- `KeyStore`：首次启动生成 Curve25519 keypair，private 存 Keychain（accessibleAfterFirstUnlockThisDeviceOnly）。
- `ensureRegisteredIfCloud()`：在 cloud mode 下如缺 api_key 自动注册；403（后端为 single-user）时记号跳过，不再重试。
- Settings tab 加了 Storage 切换、Agent Setup 复制按钮、用户 ID 展示、Regenerate key 按钮。
- broadcast extension 通过 app-group key（`ingest_ws_token`）自动拿到 api_key 作为 WS Bearer。

**Skill runbook (skill/SKILL.md)**
- 新增 Self-Hosted Setup 小节：0 前置 → 1 clone → 2 `openssl rand -hex 32` → 3 venv+deps → 4 env → 5 systemd → 6 smoke → 7 Caddy（可选）→ 8 告诉用户 → 9 端到端验收；每一步都带 **Verify** 行。
- 新增 troubleshooting 表（chat bridge / MCP 401 / Live Activity / frames not arriving）。

**部署 (deploy/)**
- `feedling.env.example` 加 `SINGLE_USER`、`FEEDLING_MCP_TRANSPORT`。
- `setup.sh` 新增 `--install-caddy` 开关，能自动 `openssl rand -hex 32` 并写 env 文件。
- `Caddyfile` 给 `/v1/chat/poll` 长轮询放宽 response timeout 到 90s。

**测试**
- `backend/test_api.py` 加 `--multi-tenant` 和 `--key <shared>` 两种模式；
  新增 Section 8（isolation + 401 + Bearer + query-key + whoami）；single-user 也保持全绿。
- 本地和测试 EC2 (`ec2-34-228-180-146`) 全通过；MCP SSE 端到端：initialize → tools/list → tools/call bootstrap 在正确/错误 key 下表现都对。

---

## 2026-04-18

### [DONE] Phase 0 T0.1 + Phase 1 T1.1/T1.2/T1.3 + Phase 2 T2.1-T2.5 + T3.1/T3.2/T4.2

**后端 (backend/app.py)**
- 新增 identity card HTTP endpoint（init/get/nudge），5 维固定
- 新增 memory garden HTTP endpoint（add/list/get/delete）
- 新增 bootstrap endpoint（first_time 返回 instructions，already_bootstrapped 防重复）
- T3.1：删除 `should_notify`，改为 `rate_limit_ok`（纯平台层 flag）
- T3.2：push payload 通用化，ContentState 改为 title/subtitle/body/personaId/templateId/data
- T4.2：`bootstrap_events.jsonl` 日志（bootstrap_started / identity_written / memory_moment_added）

**MCP server (backend/mcp_server.py)**
- 新建 FastMCP server，14 个 tool，全部调 localhost:5001
- push tool 参数同步更新为新 ContentState 字段

**部署 (deploy/)**
- Caddyfile：mcp.feedling.app → 5002，api.feedling.app → 5001
- 3 个 systemd service（feedling-backend / feedling-mcp / feedling-chat-bridge）
- setup.sh + feedling.env.example

**iOS (testapp/)**
- T3.2：ScreenActivityAttributes.ContentState 改为通用字段
- T3.2：ScreenActivityWidget.swift 渲染 title/body/subtitle
- T2.4：AppTab 扩展为 chat/identity/garden/settings 四 tab
- T2.1：IdentityView.swift + IdentityViewModel.swift（radar chart，5 维，10s 轮询）
- T2.2：MemoryGardenView.swift + MemoryViewModel.swift（卡片列表，10s 轮询，新卡片高亮）
- T2.3：Settings 加 Connection section（API URL + pairing code 占位符）
- T2.5：bootstrap 检测（identity nil → non-nil 时自动切到 Identity tab）
- FeedlingTestApp.swift：注入 IdentityViewModel / MemoryViewModel

### [DECISION] chat_bridge 改为 opt-in，默认不启动

- chat_bridge.py 是临时 Hermes 自动回复桥，有了真 MCP Agent 后会冲突
- 迁移到 systemd 后 feedling-chat-bridge service 只 install 不 enable
- Hermes 用户手动 `systemctl enable feedling-chat-bridge`，Claude.ai / OpenClaw 用户不需要跑

### [DECISION] 身份卡维度固定 5 个

- v1 先硬编码 5 维，UI 定稿后再调整
- 影响：T1.1 数据库 schema dimensions 数组长度验证改为 exactly 5；Open Decision #1 关闭

### [DECISION] 删除 T0.2 OAuth server，不做

- Claude.ai connector UI 只需填 Name + URL，不需要 OAuth
- 删除 ROADMAP T0.2（OAuth 2.1 + Dynamic Client Registration）
- 删除 Open Decision #1（自建 vs Auth0）
- 影响：PROJECT_BRIEF Section 6.1 和 Section 7.1 去掉 OAuth 相关描述

---

## 2026-04-18

### [BRIEF][ROADMAP] 项目起点 / Project kickoff

- 建立 `PROJECT_BRIEF.md` 和 `ROADMAP.md` 两份文档
- 两周 roadmap：Phase 0（MCP server 层）→ Phase 1（身份卡 + 记忆花园后端）→ Phase 2（iOS UI 粗糙版）→ Phase 3（技术债）→ Phase 4（内测准备）
- 目标用户：人机恋群体 + 用 Claude / ChatGPT / 自跑 Agent 的技术派
- 内测渠道：300 人的人机恋群里挑 30-100 人
- 核心原则：Feedling 不替换只增补；身体 vs 大脑；Feedling 没有意见
- 关键产品决定：Claude.ai 用户的记忆花园数据来源 = Agent 自己用 `conversation_search` 搜历史，Feedling 不导入任何 Claude 数据

### [ROADMAP] 记下 4 个 Open Decisions 待定

1. OAuth server 自建还是 Auth0
2. 身份卡维度数量严格 3-5 还是完全自由
3. Persona 系统 v1 要不要对用户可见
4. UI 设计稿定稿时间

---

## 模板示例（删掉或保留都行）

以下是几条示例，展示不同情境下该怎么记：

---

## 2026-04-22（示例）

### [DONE] Phase 0 完成
- T0.1 FastMCP server 层跑通
- T0.2 OAuth 用了 Auth0 免费 tier（见下面 DECISION）
- T0.3 Caddy + Let's Encrypt 部署在 `mcp.feedling.app`
- T0.4 claude.ai 里成功添加 custom connector，推送 "hello from Claude" 到灵动岛成功
- **实际用时：2.5 天（估计 3 天，稍快）**

### [DECISION] OAuth 用 Auth0 不自建
- **选择**：Auth0 免费 tier
- **原因**：两周 scope 下自建 OAuth 2.1 + DCR 风险太高，Auth0 能节省 2 天
- **影响**：v2 可能会自建替换，届时需要迁移策略
- **影响文档**：ROADMAP Open Decisions #1 勾掉

---

## 2026-04-25（示例）

### [UI] 设计师给出身份卡/记忆花园定稿
- 新增 `docs/UI_SPEC.md`
- 身份卡确定为六边形（不是五边形），6 维
- **影响 Open Decision #2**：维度数量定为严格 6 维（不是 3-5）
- **影响 ROADMAP**：
  - 新增 Phase 2.5 "UI polish"，预计 2 天
  - Phase 1 的 identity schema 里 dimensions 数组长度约束改为 6
  - 已写入数据库的测试数据需要 migration

### [ROADMAP] 删除一个 task
- T3.5 "Mock endpoint 清理" 挪到 v2，v1 不做

---

## 2026-05-02（示例）

### [FEEDBACK] 内测第一周反馈
- 15 个用户接入成功，3 个卡在 Claude.ai connector 授权环节
- 共同痛点：onboarding guide 里没讲"为什么要 OAuth"，用户警惕
- **动作**：改 `docs/onboarding/claude_ai.md`，加一段"Feedling 拿到什么、拿不到什么"的解释
- 2 个用户反馈身份卡维度看不懂——维度名字是 Agent 写的，但没有解释文字默认不展开
  - **动作**：T2.1 改，默认展开第一维的 description

### [PIVOT] 削减 ChatGPT 用户支持
- 内测发现 ChatGPT Developer Mode 流程太复杂，3 个想接的都放弃了
- **决定**：v1 内测不再主推 ChatGPT 路径
- **影响**：`PROJECT_BRIEF.md` Section 6.3 → 改成"Claude.ai / Claude Desktop / 自跑 Agent"三类；ChatGPT 挪到"Not in scope"
- **不删除相关代码**——只是不在 onboarding 里提

---

（示例结束。实际使用中，删除上面三条示例，只保留真实发生的记录。）
