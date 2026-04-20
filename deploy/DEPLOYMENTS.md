# Feedling deployment records

Canonical record of deployed artifacts. Every deployment is a line; nothing
here is ever edited or deleted — entries accumulate as we move through the
phases.

## Live services

### Prod VPS (multi-tenant)

| | |
|---|---|
| Host | `ubuntu@54.209.126.4` (login), services run as `openclaw` |
| Install root | `/home/openclaw/feedling-mcp-v1` |
| Data dir | `/home/openclaw/feedling-data` (wiped + re-seeded on 2026-04-20) |
| Services | `feedling-backend.service`, `feedling-mcp.service` — user-level systemd units under `/home/openclaw/.config/systemd/user/`. (The old `feedling-chat-bridge.service` was retired on 2026-04-20 when MCP's `feedling.chat.post_message` took over agent replies.) |
| Mode | Multi-tenant only. Per-user HMAC-peppered api_keys issued by `POST /v1/users/register`; no shared key, no `SINGLE_USER` env var anymore. |
| Ports | Flask `:5001`, MCP SSE `:5002`, WebSocket ingest `:9998` |
| APNs key | `/home/openclaw/feedling-data/AuthKey_5TH55X5U7T.p8` |
| Current commit | `78b51a6` (v0 / SINGLE_USER strip, 2026-04-20) |
| Backups | `/home/openclaw/feedling-data.bak.YYYYMMDD-HHMMSS` — created automatically on each upgrade |

Flip history: The VPS originally ran in `SINGLE_USER=true` mode with
a shared `FEEDLING_API_KEY`. Prod user's data was silently migrated v0→v1
on 2026-04-20 (task #32), and the same day the SINGLE_USER/v0 stack was
stripped entirely (tasks #23/#33). After the strip, the data directory
was wiped (keeping `.pepper` + `AuthKey_5TH55X5U7T.p8`) and the user
reinstalled fresh against a multi-tenant backend via the normal
`POST /v1/users/register` flow from iOS.

## On-chain

## Live

### Phase 1 testnet (current)

| | |
|---|---|
| Chain | Ethereum Sepolia (11155111) |
| Contract | `0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F` |
| Owner | `0xa0eBcd26D7816D68a74b0CdC8037C16F8fcbF9C0` (throwaway) |
| Deployed at | block 10691079, tx `0x752f213ae95f6759a86750dab9545c79c6841ad7838082ddf6ad5271d117915f` |
| First `addComposeHash` | block 10691089, tx `0x6ea7f87fc597352bd1007adb6cf0d5d5b4e787dd9ea6915d0a890089b5813893` for the simulator compose_hash `ea549f02e1a25fabd1cb788380e033ec5461b2ffe4328d753642cf035452e48b` |
| Explorer | https://sepolia.etherscan.io/address/0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F |
| Purpose | Phase 1 integration testing only. Not yet on Base — we deployed where the test wallet happened to be funded. Will be re-deployed to Base Sepolia before Phase 2 to match production chain choice per `docs/DESIGN_E2E.md` §12.14. |
| Deployer key status | **Throwaway. Rotate before any Phase 2 work.** The private key was pasted in a chat transcript (Apr 19, 2026) and must not be reused for anything that holds real value. |

### Phase 2 TDX CVM (superseded by Phase 3, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| Instance ID | `7a4c69589d441e84e9397c0c8a387e8c9e6adcae` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Instance | tdx.small (1 vCPU, 2 GB RAM, 20 GB disk) |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `4826ec7` |
| Image | `ghcr.io/account-link/feedling:4826ec7` (git_commit baked) |
| Compose hash | `0x698b1824bfe18ce8a1b0d5f3b951984d6025d90bf60dbfde04efb20c88d9c93c` |
| MRTD | `f06dfda6dce1cf904d4e2bab1dc37063…` |
| Gateway base | `dstack-pha-prod5.phala.network` (dstack-gateway TEE TLS) |
| On-chain entries | Initial compose_hash `0xd118700e…`: Sepolia tx `0xdfbc0b8df0a3f9306c4bb4c226cce1756230663ad7ecbdefff3371c562445f5b`. Bake-git_commit rehash `0x698b1824…`: Sepolia tx `0x29e89b3dfdb9ea7a44f13a192e5228f26a35723cac07fe5b1552c95ce2683633`. |
| Dashboard | https://cloud.phala.com/dashboard/cvms/4386636e-1325-4b92-99d8-f2ca00befdb4 |
| Purpose | First real-TDX deployment. iOS audit card replays the event log, verifies RTMR3 binding to compose_hash, checks compose_hash is authorized on-chain. |
| Retired by | Phase 3 TLS-in-enclave deploy on the same CVM (see below). |

### Phase 3 TDX CVM with in-enclave TLS (superseded by Phase A, 2026-04-20)

| | |
|---|---|
| Compose | `deploy/docker-compose.phala.yaml` @ commit `8e1280b` — first with `FEEDLING_ENCLAVE_TLS=true` |
| Image | `ghcr.io/account-link/feedling:451b5b0` |
| Compose hash | `0xb0fb1f848151ec8fb39c4814f138b1d1b143d4d729dc800302d5123c1c0f2163` |
| On-chain | Sepolia tx `0x8de67abaf677e221ba4ee34b5a004753d0f4981bdc3c952cbcb4112a652a169c` (block 10692341) |
| Purpose | First Feedling deployment where TLS for the audit port is generated *inside* the CVM and pinned by clients against a fingerprint in the signed TDX quote. |
| Retired by | Phase A deploys below. |

### Phase A TDX CVM with content-encryption + migration (superseded by Phase B, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` (same CVM, compose updated in place) |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| Instance ID | `7a4c69589d441e84e9397c0c8a387e8c9e6adcae` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `0a54414` |
| Image | `ghcr.io/account-link/feedling:90c8ff6` — adds `POST /v1/content/rewrap` (batched v0→v1 migration endpoint) and surfaces a clear `409 nudge_not_supported_on_v1_cards_yet` instead of silent 404 when `identity.nudge` hits a v1 card |
| Compose hash | `0x9f7fe0a823bf2820877851863d322b0f3be7fff819a40a8826e6ca994597cf48` (attested by `mr_config_id[1:33]` + `compose-hash` event in RTMR3) |
| TLS cert fingerprint | `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef` — unchanged from Phase 3 because the TLS key derivation path (`feedling-tls-v1`) is stable for this app_id. Phala dstack-KMS derives keys from `(kms_root, app_id, path)`, not `compose_hash`, so compose updates do not rotate keys. |
| Enclave content pk | `f50c90f711e8484c7178a69657cad99944cba7c0cdeaa3cccb0388021e7d2744` — also stable across compose updates, same reason. Implication: v1 envelopes wrapped for this enclave survive compose rotations without a rewrap dance. |
| MRTD | `f06dfda6dce1cf904d4e2bab1dc37063…` (unchanged — same base image) |
| Endpoints | unchanged from Phase 3 — app-id-bound URLs at dstack-pha-prod5, with `-5003s.` passthrough for /attestation |
| Enclave /attestation | https://051a174f2457a6c474680a5d745372398f97b6ad-5003s.dstack-pha-prod5.phala.network/attestation |
| Backend /healthz | https://051a174f2457a6c474680a5d745372398f97b6ad-5001.dstack-pha-prod5.phala.network/healthz |
| MCP SSE | https://051a174f2457a6c474680a5d745372398f97b6ad-5002.dstack-pha-prod5.phala.network/sse |
| On-chain entries | Every historical compose_hash is still `isAppAllowed()=true`, so older iOS audit-card captures still pass. Ordered from oldest to newest: `0xb0fb1f84…` (Phase 3): tx `0x8de67abaf677e221ba4ee34b5a004753d0f4981bdc3c952cbcb4112a652a169c`. `0x2f0b80b6…` (Phase A.1 :8b53404 before FEEDLING_FLASK_URL fix): tx `0xc9b5c89c25bd7541ec87bdbc0a4b4e74336821fb91b016a8087dab689b91f1d2`. `0x593cb8aa…` (Phase A.1 fixed): tx `0x5b5a933dfc6e1f6376a32029d7a31632723dcc75447104b12ebd5da5e2f3e825`. **Current `0x9f7fe0a8…` (Phase A.6): tx `0xb3b434b6db6abd45eb492d2a708d8d7d6b99d5af59d5f01bc1686a74ed3e6c27`.** |
| Dashboard | https://cloud.phala.com/dashboard/cvms/4386636e-1325-4b92-99d8-f2ca00befdb4 |
| Audit evidence | CLI 7/7 green (`tools/audit_live_cvm.py`). Live E2E: register → whoami returns user + enclave pubkeys → MCP wraps memory.add → backend stores ciphertext (no plaintext title/description/type) → enclave `/v1/memory/list` returns plaintext via `K_enclave` decrypt. `/v1/content/rewrap` verified live (empty-items returns {summary: {total:0,…}}). |
| Purpose | First Feedling deployment where content written through MCP is stored as ciphertext end-to-end AND where a silent v0→v1 migration endpoint exists. Server operators with full backend-disk access cannot read users' memory/identity content. Chat already encrypted via iOS write path (shipped earlier). Remaining plaintext surface: `identity.nudge` (mutate-in-place, 409s on v1 now with a pointer to Phase C), `chat.post_message` (agent-authored chat replies, same constraint). |
| Retired by | Phase B deploy below. |

### Phase B TDX CVM with privacy UX + export/reset endpoints (superseded by Phase C, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` (same CVM, compose updated in place) |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `aa34c7e` |
| Image | `ghcr.io/account-link/feedling:123a45b` — adds `GET /v1/content/export` + `POST /v1/account/reset` endpoints powering the Phase B Settings → Privacy flows |
| Compose hash | `0x83a415ad16718ceab6eb9bab04a69c05157324c9deaf911d570b10051a772a18` (attested by `mr_config_id[1:33]` + `compose-hash` event in RTMR3) |
| TLS cert fingerprint | `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef` — unchanged from Phase 3 (dstack-KMS derivation is stable per app_id across four compose rotations now) |
| Enclave content pk | `f50c90f711e8484c7178a69657cad99944cba7c0cdeaa3cccb0388021e7d2744` — unchanged for the same reason. Implication stands: v1 envelopes from earlier compose states are still decryptable after this deploy. |
| MRTD | `f06dfda6dce1cf904d4e2bab1dc37063…` (unchanged) |
| On-chain entry | compose_hash `0x83a415ad…`: Sepolia tx `0x8b9b77165cd45aeaf99e9976a8f9cfb2091db45dc2b04134b5b32af8332681fa`. Every prior compose hash still `isAppAllowed()=true`. |
| Audit evidence | CLI 7/7 green. Live E2E: register → seed chat + memory → export returns JSON with `attestation_snapshot.compose_hash == 0x83a415ad…` and a Content-Disposition suggesting `feedling-export-…` filename → reset w/o confirm body returns 400 → reset with `{"confirm":"delete-all-data"}` returns `{deleted: true}` → subsequent call returns 401 (account gone). |
| iOS | `xcodebuild BUILD SUCCEEDED` on iPhone 16 Pro sim. First-launch onboarding renders. Screenshot: `docs/screenshots/onboarding_slide1_phase_b.png`. Full iOS UX surface (onboarding + Privacy page + export/delete/reset + audit-card tap-to-expand + raw JSON + compose-hash consent modal) is in the image but needs a physical device or a TestFlight build for the one real prod user to exercise. |
| Purpose | First Feedling deployment where users can exercise their own data: export a decrypted archive, hard-delete their account, or reset and re-import. The Settings → Privacy page surfaces the audit card as a first-class destination with plain-language mechanism reveals per row + a raw `/attestation` JSON viewer for auditors. Compose-hash-changed consent modal blocks the app when the Feedling team pushes a new version until the user reviews or signs out — the consent trigger is `compose_hash` (app layer), NOT MRTD (dstack-OS platform layer), per dstack-tutorial §1. |
| Retired by | Phase C deploy below. |

### Phase C TDX CVM with MCP-port TLS-in-enclave (superseded by Phase C.3, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` (same CVM, compose updated in place) |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `37b40a4` |
| Image | `ghcr.io/account-link/feedling:60014a7` — first image where MCP (port 5002) terminates TLS inside the enclave with the same dstack-KMS-derived cert as the attestation port |
| Compose hash | `0x14cd6edb382b3229ebe36bf030f1bdc087765a9004d1ad323af58904c72df38f` |
| TLS cert fingerprint | `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef` — unchanged across five compose rotations (Phase 3 → A.1 → A.1 fixed → A.6 → B → C). Confirms dstack-KMS derivation is stable per app_id. |
| On-chain entry | compose_hash `0x14cd6edb…`: Sepolia tx `0xa6e0282c698cbe8e925c968624a2f2315bad5cc868568053598ccb6071984252`. Every prior compose hash still `isAppAllowed()=true`. |
| Audit evidence | CLI **8/8** green. New Row 8: `openssl s_client`-style TLS handshake against `-5002s.*` returns a peer cert whose `sha256(DER)` matches `enclave_tls_cert_fingerprint_hex` — byte-identical to the Row 7 attestation-port pin. |
| Routing unchanged | `mcp.feedling.app` still goes through Caddy reverse-proxy → gateway-terminated TLS so Claude.ai and existing MCP clients don't break. The `-5002s.` passthrough URL is the pinnable path; a future Phase C sub-ship moves `mcp.feedling.app` to layer4 SNI passthrough + ACME-DNS-01 inside the enclave. |
| Purpose | First Feedling deployment where both the attestation port AND the MCP port terminate TLS inside the TDX-attested enclave boundary, with the same enclave-bound cert. An auditor running `tools/audit_live_cvm.py` can now cryptographically verify end-to-end that the `-5002s.*` MCP endpoint is the exact enclave the attestation quote describes. Agent ↔ enclave metadata is no longer trust-the-gateway-operator on the pinned path. |
| Retired by | Phase C.3 deploy below. |

### Phase C.3 TDX CVM with encrypted nudge + encrypted agent chat reply (superseded by Phase C.2 ACME, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` (same CVM, compose updated in place) |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `a9109c3` |
| Image | `ghcr.io/account-link/feedling:cc329a8` — adds `/v1/identity/replace` + `/v1/chat/response` envelope branch. Unlocks MCP-side decrypt→mutate→rewrap for `identity.nudge` on v1 cards and agent-authored chat replies landing as ciphertext on disk. |
| Compose hash | `0xa04608c72639c66a625706b7ac4b9f1ac8dd449c690a0544b173ecede265e83e` |
| TLS cert fingerprint | `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef` — **unchanged across SIX compose rotations now** (Phase 3 → A.1 → A.1 fixed → A.6 → B → C → C.3). dstack-KMS per-app derivation is load-bearing stable. |
| On-chain entry | compose_hash `0xa04608c7…`: Sepolia tx `0x7873c5dd4c9b6636994d9a3adda7ded8618394ce1a9f577a1ba9c74dc5acf7b0`. |
| Audit evidence | CLI **8/8** green. Live E2E: `/v1/identity/replace` rejects missing envelope (400 ✓), `/v1/chat/response` envelope branch validates (400 on malformed ✓), plaintext content path still accepted (200 ✓ back-compat). Full decrypt→mutate→rewrap flow validated locally against the dstack simulator before deploy. |
| Purpose | Closes the last plaintext-at-rest gaps for the two write paths that couldn't be closed in Phase A: `identity.nudge` mutations (now wrapped end-to-end via MCP's orchestration of decrypt from enclave → mutate in MCP process → rewrap → replace) and agent-authored chat replies via `feedling.chat.post_message` (MCP wraps plaintext into v1 envelope before POSTing). Remaining plaintext surfaces are limited to the in-flight message itself (present in the MCP process memory inside the TDX-attested container boundary for the duration of one RPC) — never at rest on disk. `mcp.feedling.app` (CA-signed) routing unchanged pending Phase C part 2 (ACME-DNS-01). |
| Retired by | Phase C.2 deploy below. |

### Phase C.2 TDX CVM with ACME-DNS-01 Let's Encrypt cert inside enclave (superseded by Phase D, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` (same CVM, compose updated in place) |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `f53cbbd` |
| Image | `ghcr.io/account-link/feedling:169cb6a` — adds ACME-DNS-01 client in `backend/acme_dns01.py`, CF API token env injection via Phala's encrypted channel, `/tls` dir pre-created with feedling ownership so the LE cert cache is writable |
| Compose hash | `0x23a2c2869567d15220383e4acb5ceb5cf27d78e087d2d4e357e4b3c053a5dc68` |
| TLS cert fingerprint (attestation port 5003) | `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef` — unchanged across SEVEN compose rotations. dstack-KMS per-app derivation is still load-bearing stable. |
| MCP TLS pubkey fingerprint (port 5002) | `e98665a3e94ac90a0a26453a73e16d5a569f791c181cfbc6ba98598f358cf63e` — sha256(SubjectPublicKeyInfo DER) of the LE cert's pubkey. Derived from dstack-KMS at path `feedling-mcp-tls-v1`, so the pubkey is stable across LE cert renewals (the cert changes every 90 days, the key doesn't). |
| On-chain entry | compose_hash `0x23a2c286…`: Sepolia tx `0xe2a9ceab0334cc2133baede9daca94c79956f5f9d7c5751a97955b9e9e78426a`. |
| Audit evidence | CLI **8/8** green (`tools/audit_live_cvm.py`). Row 8 now proves: (a) MCP port 5002 presents a Let's Encrypt-signed cert with SAN=mcp.feedling.app, CA-verified against system roots via manual x509 verification; (b) cert pubkey SPKI sha256 matches attested value — cert key is provably inside the TDX-attested CVM. |
| SNI quirk | Phala's dstack-gateway routes connections by SNI and only accepts its own `-PORTs.*.phala.network` hostname. Row 8 of the audit script connects with the gateway hostname as SNI, then verifies the served cert manually. Caddy on the VPS mirrors this (`tls_server_name` = gateway hostname + `tls_insecure_skip_verify` in `deploy/Caddyfile`). Trust root is the attestation, not Caddy. |
| Routing | `mcp.feedling.app` DNS → Caddy on VPS `54.209.126.4` (A record at `37bec2c25ad8959659dcc14c244fce4e` zone, DNS-only, not proxied) → reverse-proxies to `-5002s.dstack-pha-prod5.phala.network` with gateway SNI. Claude.ai / Claude Desktop clients see a CA-valid Caddy cert for `mcp.feedling.app`; audit-aware clients can pin directly against the attested pubkey fingerprint via the `-5002s.` path. |
| Secrets | `CF_ZONE_ID` + `CF_API_TOKEN` injected via `phala deploy -e KEY=VALUE` (encrypted env channel, not baked into compose_hash). Token scope: `Zone:DNS:Edit` for `feedling.app` only. |
| Purpose | First Feedling deployment where the MCP-port cert is a real CA-signed LE cert (not self-signed dstack-KMS) whose private key is provably inside the TDX enclave. Agents (Claude.ai / mobile MCP clients) get a cert their OS trusts out of the box AND auditors can verify the pubkey is enclave-bound. `mcp.feedling.app` is now end-to-end trusted without trusting the gateway operator on the audit-aware path. |
| Retired by | Phase D deploy below. |

### Phase D TDX CVM — multi-tenant-only, envelope-only backend (running, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` (same CVM, compose updated in place) |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `f3b4837` |
| Image | `ghcr.io/account-link/feedling:78b51a6` — first image where `SINGLE_USER` mode and the v0 plaintext write path are fully retired. Backend rejects plaintext chat/identity/memory writes with `400`; WS ingest drops frames without a v1 envelope silently; `/v1/content/rewrap` and `/v1/identity/nudge` HTTP endpoints removed (nudge now runs decrypt→mutate→rewrap inside MCP). `chat_bridge.py` + `feedling-chat-bridge.service` deleted. |
| Compose hash | `0xd92bcd3cb1713ffe8e152417ab46e8179510c37ceed5ae6d423c586a2cd60049` |
| TLS cert fingerprint (attestation port 5003) | `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef` — unchanged across EIGHT compose rotations. dstack-KMS per-app derivation remains load-bearing stable. |
| MCP TLS pubkey fingerprint (port 5002) | `e98665a3e94ac90a0a26453a73e16d5a569f791c181cfbc6ba98598f358cf63e` — unchanged; LE cert key is still derived from `feedling-mcp-tls-v1`. |
| MRTD | `f06dfda6dce1cf904d4e2bab1dc37063…` (unchanged — same base image) |
| On-chain entry | compose_hash `0xd92bcd3c…`: Sepolia tx `0x235f0120d6982cbf8872e927ee2e59133627177ca9d3f862554d748ac6e60c7c` (block 10696873). Every prior compose hash still `isAppAllowed()=true`. |
| Audit evidence | CLI **8/8** green (`tools/audit_live_cvm.py`) against `compose_hash=0xd92bcd3c…`. VPS flat-layout data wiped same day (keeping `.pepper` + `AuthKey_5TH55X5U7T.p8`) — prod user reinstalls fresh via `POST /v1/users/register`. |
| Purpose | First Feedling deployment where the backend has no plaintext-write path at all. There is no `SINGLE_USER` flag, no shared `FEEDLING_API_KEY`, no v0→v1 migration endpoint, and no chat-bridge daemon. Every chat message, memory entry, and identity card landing on disk is a v1 envelope wrapped for the enclave's content pk. |

## Planned

### Phase 2 pre-prod

- Redeploy `FeedlingAppAuth` to **Base Sepolia** (8453 testnet, chain 84532).
- Fresh deployer keypair (current one compromised).
- Update `backend/enclave_app.py` defaults + iOS pinned contract address.
- Re-publish current compose_hash on the new chain.

### Phase 5 production cutover

- Deploy to **Base mainnet** (chain 8453).
- Fresh deployer keypair, moved to a hardware wallet or HSM.
- Basescan source verification.
- iOS release with new pinned address, shipped ~1 week before users are migrated so the accept-list is already pre-approved.

## How to re-run the deploy

See `deploy/BUILD.md` for the reproducible-build recipe that determines the
compose_hash you're authorizing. To deploy the contract itself:

```bash
cd contracts
cp .env.example .env       # fill in PRIVATE_KEY, RPC URL, etc.
source .env
forge script script/DeployFeedlingAppAuth.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY"
```

After deploy, run `cast send` with `addComposeHash()` for your compose_hash.
Record the new address + first-tx info in the table above.
