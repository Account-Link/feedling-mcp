# Feedling — Handoff

Snapshot of the project at the end of the autonomous build sprint that
closed NEXT.md Phase 2. Whoever picks this up next — start here.

## TL;DR

- **What's live**: iOS app with end-to-end encrypted chat / memory / identity /
  frames, talking to a Flask+MCP backend on `api.feedling.app`/`mcp.feedling.app`
  over HTTPS, plus a real Intel-TDX enclave on Phala Cloud that attests itself.
- **What's verifiable**: anyone can hit the enclave's `/attestation` endpoint,
  run `tools/audit_live_cvm.py`, and get a 6/6 green audit card proving that
  the exact `docker-compose.phala.yaml` in this repo is what's running, that
  Intel's DCAP chain signs the quote, and that the `compose_hash` is
  authorized on FeedlingAppAuth (Eth Sepolia).
- **What's deferred**: Phase 3 TLS-in-enclave (see last section).

## Key endpoints

| What | URL |
|---|---|
| iOS API (HTTPS) | `https://api.feedling.app` |
| MCP SSE (HTTPS) | `https://mcp.feedling.app/sse?key=<api_key>` |
| Phala CVM /attestation | `https://051a174f2457a6c474680a5d745372398f97b6ad-5003.dstack-pha-prod5.phala.network/attestation` |
| Phala CVM MCP | `https://051a174f2457a6c474680a5d745372398f97b6ad-5002.dstack-pha-prod5.phala.network/sse` |
| FeedlingAppAuth contract | Eth Sepolia `0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F` |
| Container image | `ghcr.io/account-link/feedling:<commit>` (public) |
| CI workflow | `.github/workflows/docker-publish.yml` |

## State of each priority

| # | Priority | Status | Where |
|---|---|---|---|
| 1 | Chat decryption in iOS | Done | `testapp/FeedlingTest/ChatMessage.swift`, `ChatViewModel.swift` |
| 2 | Memory + identity decryption | Done | `MemoryViewModel.swift`, `IdentityViewModel.swift` |
| 3 | Phala TDX deploy | Done | CVM running, `deploy/DEPLOYMENTS.md` §Phase 2 |
| 4 | Frame encryption (broadcast ext) | Done | `FeedlingBroadcast/FrameEnvelope.swift` |
| 5 | Prod HTTPS | Done | Caddy on VPS, Let's Encrypt certs for both hostnames |
| 6 | iCloud Keychain for content keys | Done | `FeedlingAPI.swift` ContentKeyStore + KeyStore |

Plus on-chain `compose_hash` authorization, reproducible CI builds,
command-line audit tool, live-TDX audit card screenshot in
`docs/screenshots/audit_card_phase2_live_tdx.png`.

## How to release a new version

1. `git commit` + `git push origin main` — this triggers
   `.github/workflows/docker-publish.yml`.
2. CI builds `linux/amd64` image at `ghcr.io/account-link/feedling:<commit>`
   with `FEEDLING_GIT_COMMIT` and `FEEDLING_BUILT_AT` baked in.
3. Bump the image pin in `deploy/docker-compose.phala.yaml` (three places).
4. `phala deploy --cvm-id feedling-enclave -c deploy/docker-compose.phala.yaml`
5. `phala cvms start feedling-enclave`
6. Wait until `/attestation` returns 200 (2–3 min).
7. Read the new `compose_hash` from `/attestation`.
8. Publish it on-chain:
   ```bash
   set -a; source contracts/.env; set +a
   cast send --rpc-url "$ETH_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY" \
       "$FEEDLING_APP_AUTH_CONTRACT" \
       "addComposeHash(bytes32,string,string)" \
       "0x<new_hash>" "<label>" "<notes>"
   ```
9. Update `testapp/FeedlingTest/FeedlingAPI.swift` `attestationURL` and
   `testapp/FeedlingTest/AuditCardView.swift` `makeAttestationURL` if the
   hostname shape changes. (It won't for minor releases.)
10. Run `tools/audit_live_cvm.py` — all 6 rows should be green.

## How to update the VPS (non-enclave services)

```bash
SSH_KEY=/path/to/timeline-tuner-dashboard-dev.pem
ssh -i $SSH_KEY ubuntu@54.209.126.4 "sudo -iu openclaw bash -c '
    cd ~/feedling-mcp-v1 && git pull --ff-only origin main &&
    ~/feedling-mcp-v1/backend/.venv/bin/pip install -qr backend/requirements.txt &&
    pkill -f \"feedling-mcp-v1/backend/app.py\" &&
    pkill -f \"feedling-mcp-v1/backend/mcp_server.py\" &&
    pkill -f \"feedling-mcp-v1/backend/chat_bridge.py\"'"
# systemd Restart=always brings them back.
```

Note: repo path on the VPS is still `feedling-mcp-v1/` (was not renamed
server-side when the GitHub repo was renamed to `feedling-mcp`). Both URLs
redirect so git pull works fine.

## Directory map

```
backend/
  app.py                       # Flask API (HTTP + WS ingest)
  enclave_app.py               # TDX enclave service (/attestation + decrypt)
  mcp_server.py                # FastMCP SSE for Claude.ai
  chat_bridge.py               # agent-side long-poll bridge
  semantic_analysis.py         # keyword-based screen classifier
contracts/                     # Foundry project, FeedlingAppAuth.sol
  .env                         # deployer key + RPCs (gitignored)
deploy/
  Dockerfile                   # hash-pinned base + --require-hashes deps
  docker-compose.yaml          # single-box self-host compose
  docker-compose.phala.yaml    # Phala CVM compose (3 services)
  Caddyfile                    # prod HTTPS
  publish-compose-hash.sh      # compute + publish compose_hash on-chain
  setup.sh                     # bootstrap a fresh VPS
  DEPLOYMENTS.md               # every deployed artifact, one line each
  BUILD.md                     # reproducible build recipe
docs/
  DESIGN_E2E.md                # full architecture (Phase 1–5)
  audit/                       # frozen Phase-2 attestation + audit output
  screenshots/                 # UI proofs
ios/FeedlingDCAP/              # standalone Swift package: DCAP parser + verifier
testapp/
  FeedlingTest/                # main app target (chat, garden, identity, audit)
    ContentEncryption.swift    # envelope crypto (chat/memory/identity)
    DCAP/                      # vendored-in copy for audit card
  FeedlingBroadcast/           # ReplayKit extension — captures screen frames
    FrameEnvelope.swift        # v1 envelope wrap (NEW Phase 2)
tools/
  audit_live_cvm.py            # scripted 6-row audit against any Feedling CVM
  v1_envelope_roundtrip_test.py       # backend chat/memory/identity roundtrip
  frame_envelope_roundtrip_test.py    # backend frame roundtrip
  dcap/                        # Python DCAP parser (reference for Swift port)
```

## Running locally (end-to-end dev loop)

```bash
# 1. Dstack simulator (pretends to be a TDX host)
# Setup guide: https://github.com/amiller/dstack-tutorial
# After setup, the sim socket lives at ~/.phala-cloud/simulator/0.5.3/dstack.sock

# 2. Services
rm -rf /tmp/fl && mkdir -p /tmp/fl
SINGLE_USER=false FEEDLING_DATA_DIR=/tmp/fl \
  FEEDLING_ENCLAVE_URL=http://127.0.0.1:5003 \
  PORT=5001 python3 backend/app.py &

DSTACK_SIMULATOR_ENDPOINT=$HOME/.phala-cloud/simulator/0.5.3/dstack.sock \
  FEEDLING_ENCLAVE_PORT=5003 FEEDLING_DATA_DIR=/tmp/fl \
  python3 backend/enclave_app.py &

# 3. iOS sim
UDID=$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/ {print $2; exit}')
xcodebuild -project testapp/FeedlingTest.xcodeproj -scheme FeedlingTest \
  -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath /tmp/fl-dd build
xcrun simctl install $UDID /tmp/fl-dd/Build/Products/Debug-iphonesimulator/FeedlingTest.app
SIMCTL_CHILD_FEEDLING_API_URL=http://127.0.0.1:5001 \
SIMCTL_CHILD_FEEDLING_ATTESTATION_URL=http://127.0.0.1:5003/attestation \
  xcrun simctl launch $UDID com.feedling.mcp
```

## Phase 3: what's left and why it isn't done

The iOS audit card has one amber row: **"TLS cert bound to attestation"**.

**What the problem is.** Right now the CVM is addressed as
`<app-id>-<port>.dstack-pha-prod5.phala.network`, and dstack-gateway (a
separate Phala-operated TEE) is what terminates TLS. A client connecting
there gets a Let's Encrypt cert that dstack-gateway holds; our enclave
never sees the TLS keys. So:

- A sophisticated MITM with control of dstack-gateway could intercept
  traffic.
- Our `report_data` field has a placeholder for a TLS cert fingerprint
  (`enclave_tls_cert_fingerprint_hex`), which is what auditors *would*
  pin against if the cert originated in our enclave. Currently unused.

**Why it's not a security hole** for Phase 2:
- Content (chat/memory/identity/frames) is already encrypted at the
  envelope layer before it ever hits TLS. The `body_ct` is sealed to the
  enclave's content pubkey, which IS bound into the attestation.
- Gateway TLS only protects metadata (which endpoints you hit, request
  timing, response sizes).
- dstack-gateway itself runs in a TEE with its own attestation — not a
  "plaintext linux VM" operator.

**What fixing it takes** (2–4 hours):

1. **Decide on the URL story.** Two options:
   - `-s` suffix URL — `<app-id>-<port>s.dstack-pha-prod5.phala.network`
     tells dstack-gateway to passthrough TLS to the enclave instead of
     terminating. Easiest. Keeps the Phala-provided hostname.
   - Custom DNS (`enclave.feedling.app`) pointed at the gateway IP with
     SNI-based routing. More flexible but more moving parts.
2. **Generate TLS keypair inside enclave** at boot. ECDSA P-256 (or
   X25519 for QUIC), derived from dstack-kms-derived key material so
   the private key is bound to this exact `compose_hash`.
3. **Populate `report_data`** (the 64-byte quote field) with the
   SHA256 of the TLS cert's DER-encoded SubjectPublicKeyInfo. Currently
   enclave_app.py leaves this as a placeholder; wire it up for real.
4. **Get an ACME cert** — TLS-ALPN-01 challenge works well here because
   it uses the cert itself to prove control, no separate HTTP server
   needed. `certbot` or `acme.sh` inside the enclave, triggered at boot.
5. **Serve HTTPS from Flask** — swap `app.run(port=5003)` for
   `app.run(ssl_context=(certfile, keyfile), port=443)` or put a
   Python stdlib-HTTPS (or gunicorn with SSL) in front.
6. **iOS audit card** — the row already exists in the code
   (`AuditCardView.swift:239`); just needs to actually pull the cert
   from the live URL during verification and compare its SPKI-SHA256 to
   `bundle.enclave_tls_cert_fingerprint_hex`. ~20 lines of Swift.

**Recommendation**: do this in a dedicated PR with its own end-to-end
test + screenshot, not piled onto another feature. The existing audit
card UI already explains the caveat, so there's no user-facing
regression risk from leaving it amber for now.

## Other loose ends (not urgent)

- **`git_commit` in /attestation**: now baked at CI build time (see the
  Dockerfile `ARG FEEDLING_GIT_COMMIT` and the workflow `build-args`
  block). The currently-deployed CVM image pre-dates this; it'll show
  "dev" until next deploy.
- **Broadcast extension user_id sharing**: `FrameEnvelope.swift` reads
  `feedling.userID` from the App Group UserDefaults. The main app
  writes it on every `publishContentKeysToAppGroup()`. If someone uses
  the broadcast extension before the main app has ever registered (no
  userID yet), frames fall through to legacy plaintext. Fine for now.
- **iCloud Keychain on the broadcast extension**: extension reads its
  (non-secret) public keys from App Group; no secret keys live there.
  So iCloud Keychain sync applies only to the main app's
  `ContentKeyStore` / `KeyStore`, which is correct.
- **Deployer key rotation**: `FEEDLING_APP_AUTH` owner
  `0xa0eBcd26D7816D68a74b0CdC8037C16F8fcbF9C0` was the throwaway key
  used for Sepolia bring-up. Rotate before Base mainnet per
  `DEPLOYMENTS.md`.

## Things that would surprise you

- **Prod VPS directory is `feedling-mcp-v1/`** — never renamed after the
  GitHub repo rename. git pull works via redirect.
- **Docker builds fail on this particular Mac** because the local DNS
  resolver intercepts `docker.io` (routes to `198.18.x.x`). CI on GitHub
  Actions is the only reliable way to publish images.
- **`mcp.feedling.app/attestation` returns 404** on purpose — that
  hostname is FastMCP SSE, not the attestation service. iOS audit card
  hits the Phala CVM URL directly.
- **`Don't Allow` on the notification permission prompt** requires a
  very specific AppleScript UI path on iOS Simulator — coordinate clicks
  don't register reliably. See the full path in the session transcript
  if you ever need to drive the sim UI from a script.
