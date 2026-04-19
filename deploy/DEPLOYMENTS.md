# Feedling deployment records

Canonical record of deployed artifacts. Every deployment is a line; nothing
here is ever edited or deleted — entries accumulate as we move through the
phases.

## Live services

### Prod VPS (single-user, pre-E2E)

| | |
|---|---|
| Host | `ubuntu@54.209.126.4` (login), services run as `openclaw` |
| Install root | `/home/openclaw/feedling-mcp-v1` |
| Data dir | `/home/openclaw/feedling-data` (~409 MB incl. frames) |
| Services | `feedling-backend.service`, `feedling-mcp.service`, `feedling-chat-bridge.service` — all user-level systemd units under `/home/openclaw/.config/systemd/user/` |
| Mode | `SINGLE_USER=true`, `FEEDLING_API_KEY=` (empty → no auth) |
| Ports | Flask `:5001`, MCP SSE `:5002`, WebSocket ingest `:9998` |
| APNs key | `/home/openclaw/feedling-data/AuthKey_5TH55X5U7T.p8` |
| Current commit | `5408c62` (upgraded 2026-04-19) |
| Backups | `/home/openclaw/feedling-data.bak.YYYYMMDD-HHMMSS` — created automatically on each upgrade |

Flip-to-multi-tenant plan (when iOS app with registration client ships):

1. Stop services.
2. Set `SINGLE_USER=false` in the unit file environment blocks.
3. `POST /v1/users/register` locally on the box → get `{user_id, api_key}`.
4. `mv ~/feedling-data/{chat,identity,memory,tokens,…}.json ~/feedling-data/<user_id>/` and same for `frames/`.
5. Restart services.
6. Paste the returned `api_key` into the iOS app's Settings → Storage → Self-hosted (until DNS+HTTPS for `api.feedling.app` is live).

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

### Phase 3 TDX CVM with in-enclave TLS (running, 2026-04-20)

| | |
|---|---|
| Provider | Phala Cloud (dstack-dev-0.5.8, Intel TDX) on node `prod5` (US-WEST-1) |
| Name | `feedling-enclave` (same CVM, compose updated in place) |
| App ID | `051a174f2457a6c474680a5d745372398f97b6ad` |
| Instance ID | `7a4c69589d441e84e9397c0c8a387e8c9e6adcae` |
| VM UUID | `4386636e-1325-4b92-99d8-f2ca00befdb4` |
| Compose | `deploy/docker-compose.phala.yaml` @ commit `8e1280b` (diff from 2: `FEEDLING_ENCLAVE_TLS=true` + https healthcheck + image bumped to `:451b5b0`) |
| Image | `ghcr.io/account-link/feedling:451b5b0` (first image with in-enclave TLS serving) |
| Compose hash | `0xb0fb1f848151ec8fb39c4814f138b1d1b143d4d729dc800302d5123c1c0f2163` (attested by `mr_config_id[1:33]` + `compose-hash` event in RTMR3) |
| TLS cert fingerprint | `5698f0ade4bb412d6b0847a62d695138f3bbd287dc7d1dbdeb67b15dc445e5ef` = `sha256(cert.DER)`, baked into `report_data[0:32]` |
| MRTD | `f06dfda6dce1cf904d4e2bab1dc37063…` (unchanged — same base image) |
| Endpoints (app-id-bound) | `https://051a174f…-{5001,5002,9998}.dstack-pha-prod5.phala.network` (gateway TLS) + `https://051a174f…-5003s.dstack-pha-prod5.phala.network` (**TLS passthrough to enclave**) |
| Enclave /attestation | https://051a174f2457a6c474680a5d745372398f97b6ad-5003s.dstack-pha-prod5.phala.network/attestation |
| Backend /healthz | https://051a174f2457a6c474680a5d745372398f97b6ad-5001.dstack-pha-prod5.phala.network/healthz |
| MCP SSE | https://051a174f2457a6c474680a5d745372398f97b6ad-5002.dstack-pha-prod5.phala.network/sse |
| On-chain entry | compose_hash `0xb0fb1f84…`: Sepolia tx `0x8de67abaf677e221ba4ee34b5a004753d0f4981bdc3c952cbcb4112a652a169c` (block 10692341). |
| Dashboard | https://cloud.phala.com/dashboard/cvms/4386636e-1325-4b92-99d8-f2ca00befdb4 |
| Audit evidence | `docs/screenshots/audit_card_phase3_tls_pinned.png` — 6/6 green on iOS including real TLS-binding row. |
| Purpose | First Feedling deployment where TLS for the audit port is generated *inside* the CVM and pinned by clients against a fingerprint in the signed TDX quote. An operator with dstack-gateway access can no longer MITM `/attestation` without producing a quote they can't sign. |

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
