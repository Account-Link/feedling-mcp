# Feedling — Handoff

Snapshot of the project at the end of the autonomous build sprint that
closed NEXT.md Phase 2 **and** the Phase 3 TLS-in-enclave follow-up.
Whoever picks this up next — start here.

## TL;DR

- **What's live (through Phase A, 2026-04-20)**: iOS app with end-to-end
  encrypted chat (iOS writes) + **agent-authored memory and identity cards
  now encrypted too via MCP-side envelope wrap**, talking to a Flask+MCP
  backend on `api.feedling.app`/`mcp.feedling.app`, plus a real Intel-TDX
  enclave on Phala Cloud that attests itself, terminates its own TLS on
  the attestation port, and hosts a decrypt proxy for agent reads.
- **CLI audit**: `tools/audit_live_cvm.py` → **8/8 green** against the live
  CVM. Checks `/attestation` parses, DCAP chain to Intel SGX Root CA,
  measurements non-zero + `mr_config_id[0]=0x01`, `compose_hash` authorized
  on FeedlingAppAuth (Eth Sepolia), RTMR3 event log + mr_config_id binding,
  live attestation-port TLS-cert-DER pinned to the attested fingerprint,
  and (Phase C) live MCP-port TLS-cert-DER also pinned to the same
  attested fingerprint.
- **iOS audit card**: **6/6 green**. Screenshot:
  `docs/screenshots/audit_card_phase3_tls_pinned.png`.
- **Content-plaintext status**:
  - *Encrypted on server*: chat (iOS writer), memory add, identity init.
  - *Still plaintext*: `feedling.identity.nudge` (mutate-in-place),
    `feedling.chat.post_message` (agent→user reply). Both pending Phase C
    (MCP-in-TEE) because they need decrypt→mutate→rewrap semantics.
  - *Not yet re-wrapped*: any pre-Phase-A v0 data on disk — **migration
    code now live (A.6), runs silently on the next iOS launch**. Live
    endpoint: `POST /v1/content/rewrap` on the CVM (idempotent,
    batched). Exactly one production user to verify against (noted in
    task #23); once her migration completes, v0 accept paths + the
    rewrap endpoint itself get stripped.
- *Phase C (part 1)*: shipped 2026-04-20. MCP port 5002 now
    terminates TLS inside the enclave with the same dstack-KMS-bound
    cert as the attestation port. `-5002s.` URL is pinnable; CLI
    auditor Row 8 + iOS audit card "MCP port TLS bound to
    attestation" row added.
- *Phase C.3*: shipped 2026-04-20. `identity.nudge` on v1 cards
    goes through MCP-orchestrated decrypt-mutate-rewrap (enclave
    decrypts, MCP mutates inside its TDX-container process, POSTs
    to new `/v1/identity/replace`). `feedling.chat.post_message`
    (agent replies) now wraps to v1 envelope before POSTing.
    Server disk stays ciphertext for both write paths. iOS UX fixes
    from user feedback: privacy hero row now actually taps through
    to the audit card; "On-chain audit (public transparency, not
    security)" copy → "Public release log"; new in-app links to
    `docs/AUDIT.md` (the agent-consumable "is this safe?" guide)
    and the public GitHub repo.
- *Phase C part 2 open*: ACME-DNS-01 inside the enclave so
    `mcp.feedling.app` (what Claude.ai hits) can move to layer4
    SNI passthrough and drop the "trust Caddy on the VPS" step.
    Needs a DNS API token + renewal scheduler. Task #30.
- *Phase B UX*: shipped 2026-04-20. Onboarding (3-slide),
    Settings → Privacy (hero + export / delete / reset / runbook),
    audit card promoted with tap-to-expand mechanism reveals + raw
    `/attestation` JSON viewer. Backend endpoints
    `GET /v1/content/export` + `POST /v1/account/reset` live on the
    CVM. Compose-hash-changed consent modal fires when the app
    version rotates (trigger is `compose_hash`, NOT MRTD — per
    dstack-tutorial §1 MRTD is a platform-layer signal, not an app
    signal). Two items deferred to a Phase B wave-2 commit:
    per-item visibility toggles (endpoint already supports them via
    existing rewrap, just needs the list+toggle UI) and the inline
    migration-progress row in the Privacy hero.
- *Pending copy review by @sxysun*: onboarding microcopy, audit-card
    mechanism reveals, compose-hash consent modal copy. Flagged in
    `docs/PHASE_B_PLAN.md` §4.
- **Key rotation observation worth knowing**: Phala dstack-KMS derives
  per-app keys from `(kms_root, app_id, path)`, not from `compose_hash`.
  That means `enclave_content_pk` and the enclave-TLS cert stay stable
  across compose updates for this app_id. Good: no operational rewrap
  dance needed after every deploy. Caveat: tying app trust to `app_id` +
  on-chain `isAppAllowed(compose_hash)` still gives you cryptographic
  per-compose authorization, so the security story is intact.

## ⚠ Before next agent picks this up

**All user-facing copy on the iOS audit card — row labels, captions,
inline explanations, the TLS row text (new: "sha256(cert.DER)=… matches
the value bound into the TDX quote's REPORT_DATA."), the "On-chain audit
(public transparency, not security)" wording, everything — needs a
review pass by @sxysun before it goes in front of real users.** The copy
is technically accurate but may not read right for beta users who aren't
security engineers.

Source files for that copy:
- `testapp/FeedlingTest/AuditCardView.swift` — row titles, captions,
  TLS match/mismatch text, pre-Phase-3 amber disclosure, Etherscan footer text
- `testapp/FeedlingTest/EventLogReplay.swift` — reason strings that bubble
  up into row captions
- `testapp/FeedlingTest/DCAP/Verifier.swift` — error descriptions shown
  when a row fails

Also review `docs/screenshots/audit_card_phase3_tls_pinned.png` — if the
product voice isn't right, that's the canonical reference-shot.

## Key endpoints

| What | URL |
|---|---|
| iOS API (HTTPS) | `https://api.feedling.app` |
| MCP SSE (HTTPS) | `https://mcp.feedling.app/sse?key=<api_key>` |
| Phala CVM /attestation | `https://051a174f2457a6c474680a5d745372398f97b6ad-5003s.dstack-pha-prod5.phala.network/attestation` (note `-5003s`: TLS passthrough) |
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
command-line audit tool, and **Phase 3 in-enclave TLS** — deterministic
ECDSA-P256 cert derived from dstack-KMS (bound to compose_hash), served
via passthrough at the `-5003s.` gateway route, fingerprint baked into
REPORT_DATA and pinned by iOS on every audit. Live-TDX audit card
screenshots:
- `docs/screenshots/audit_card_phase2_live_tdx.png` (5+amber, pre-Phase 3)
- `docs/screenshots/audit_card_phase3_tls_pinned.png` (6/6, current)

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

## Phase 3: what shipped (2026-04-20)

**TLS for the `/attestation` port (5003) now terminates inside the CVM.**
The iOS audit card row "TLS cert bound to attestation" went from amber
placeholder to a real comparison against a fingerprint baked into the
TDX-signed quote. MCP (5002) and the backend API (5001) still use
gateway-terminated TLS because their threat model is different — envelope
crypto protects content-plaintext, gateway TLS only protects metadata.

**What the shape of the fix is:**

- `backend/enclave_app.py` — on boot, when `FEEDLING_ENCLAVE_TLS=true`,
  derive an ECDSA-P256 keypair from dstack-KMS via a distinct path
  (`feedling-tls-v1`). Build a self-signed cert, sign it with RFC-6979
  deterministic ECDSA so the DER is byte-stable across reboots. Compute
  `sha256(cert.DER)` and pass it into `build_report_data(...)` instead
  of the zero placeholder. Serve Flask via an `ssl.SSLContext` loaded
  from transiently-materialized PEM files (unlinked immediately).
- `deploy/docker-compose.phala.yaml` — `FEEDLING_ENCLAVE_TLS=true` on the
  enclave service. Healthcheck switches to `curl -k https://127.0.0.1:5003`.
  The `-k` is expected: inside the enclave there's no way to do the
  attestation-based pin for a liveness ping.
- iOS URL — attestation fetcher moves from `-5003.` to `-5003s.`, which
  is the dstack-gateway passthrough suffix (gateway forwards TLS bytes
  instead of terminating).
- iOS pinning — `PinningCaptureDelegate` in `AuditCardView.swift`
  records `sha256(leaf cert DER)` during the handshake while accepting
  the cert (no CA chain in our trust model). After the bundle is parsed,
  the audit compares the captured hash to `enclave_tls_cert_fingerprint_hex`.
  Match = green; mismatch = hard red "MITM detected."
- `FeedlingAPI.swift`'s startup `refreshEnclaveAttestation` gets a
  companion `AttestationTrustShim` so it can still fetch the bundle over
  the self-signed TLS. This path doesn't do pinning (just metadata
  bootstrap) — the pinning check lives in the audit card, downstream.
- `tools/audit_live_cvm.py` — new Row 7: raw TLS handshake with
  `CERT_NONE` verification, compare `sha256(peer cert DER)` to the
  attested fingerprint. All-zeros fingerprint emits the pre-Phase-3
  disclosure without marking the row green.

**Trust model**: the self-signed chain is expected. An operator cannot
substitute their own TLS cert without also forging a quote signing
REPORT_DATA they can't produce — the TDX PCK signs the quote, and our
cert's DER hash is part of that signed payload.

**Test evidence**: local simulator run produced a deterministic cert
across reboots (`7e8782c261d1acd3…` twice in a row); the live CVM on
Phala runs the same code under a real TDX quote; both the CLI auditor
and the iOS audit card go 7/7 and 6/6 respectively against the live
endpoint. See `docs/screenshots/audit_card_phase3_tls_pinned.png`.

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
