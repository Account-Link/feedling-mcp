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
