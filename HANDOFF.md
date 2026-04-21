# Feedling — Handoff

Snapshot of the project as of 2026-04-20, end of the autonomous build
sprint that shipped Phases A–D + the v0/SINGLE_USER strip. An
in-flight migration to a pure-CVM architecture on Phala prod9 is
described in "Migration (in-flight, 2026-04-21)" immediately below;
the rest of this doc is the pre-migration reference.
Whoever picks this up next — start here.

## Migration (in-flight, 2026-04-21)

**Goal**: decommission the VPS. `dstack-ingress` 2.2 inside the CVM
terminates TLS for both `api.feedling.app` and `mcp.feedling.app` in a
single HAProxy container, routing by SNI to the backend (5001) and MCP
(5002) services. The prod9 gateway is required — only prod9 supports
`_dstack-app-address.<domain>` TXT-based custom-domain routing.
User explicitly chose endgame over conservative (re-onboard the single
prod user from scratch; no v0→v1-style in-place migration path).

**What changed in this commit (code + config, all committed ready for
`phala deploy`):**

- `deploy/docker-compose.phala.yaml` — added `ingress` service
  (`dstacktee/dstack-ingress:2.2@sha256:d05a7b3…`). MCP dropped its own
  ACME config + `FEEDLING_MCP_TLS=false` (plain HTTP behind ingress).
  Enclave service sets `FEEDLING_MCP_TLS_IN_ENCLAVE=false` so it leaves
  `mcp_tls_cert_pubkey_fingerprint_hex` empty in the attestation bundle.
  `GATEWAY_DOMAIN=_.dstack-pha-prod9.phala.network`.
- `testapp/FeedlingTest/CVMEndpoints.swift` — NEW. Centralized URL
  construction (attestation, ws ingest, api, mcp) driven by
  `appId` + `gatewayDomain`, overridable via
  `FEEDLING_CVM_APP_ID`/`FEEDLING_CVM_GATEWAY_DOMAIN` env or
  `feedling.cvm.appId`/`feedling.cvm.gatewayDomain` UserDefaults.
  Defaults still prod5 so pre-cutover builds work; flip in a follow-up
  commit once the prod9 app_id is known.
- `testapp/FeedlingTest/FeedlingAPI.swift` — `resolveIngestWSEndpoint`
  and `attestationURL` delegate to `CVMEndpoints`. No hardcoded VPS IP
  or app_id strings.
- `testapp/FeedlingTest/AuditCardView.swift` — three URL sites moved
  to `CVMEndpoints` (MCP pubkey-pin URL, `makeAttestationURL` default,
  `fetchRawJSON`). The MCP pubkey-pin branch is now skipped by the
  pre-existing `attestedMcpPkFp.isEmpty` guard because the migrated
  CVM leaves that bundle field empty — iOS shows the existing
  "Pre-Phase-C.2 deployment" disclosure row.
- `testapp/FeedlingBroadcast/{SharedConfig,WebSocketManager,SampleHandler}.swift` —
  broadcast extension is a separate target and can't import
  `CVMEndpoints`; it now uses `SharedConfig.defaultIngestEndpoint` as
  fallback (matches CVMEndpoints defaults). Real value is still written
  to App Group UserDefaults by `FeedlingAPI.init`.
- `backend/enclave_app.py` — MCP pubkey fingerprint derivation gated
  on `FEEDLING_MCP_TLS_IN_ENCLAVE` (default `true` for backward compat
  with any non-migrated CVM; set `false` in the new compose).
- `tools/audit_live_cvm.py` — endpoint URLs derived from env
  (`FEEDLING_CVM_APP_ID`/`FEEDLING_CVM_GATEWAY_DOMAIN`) with prod5
  defaults; Row 8 treats empty `mcp_tls_cert_pubkey_fingerprint_hex`
  as a pass-with-disclosure (ingress-terminated TLS; content-layer
  envelope crypto is the real trust boundary).
- `.github/workflows/ci.yml` — `deploy-vps` job deleted; `deploy-cvm`
  now gates on the test jobs directly. Added
  `FEEDLING_COMPOSE_FILE: deploy/docker-compose.phala.yaml` to the
  `publish-compose-hash.sh` step so on-chain authorization hashes the
  compose that actually boots prod (without this it hashed
  `docker-compose.yaml`, the local-dev compose — pre-existing bug,
  now fixed).

**Local validation done (2026-04-21)**:

- `docker compose -f deploy/docker-compose.phala.yaml config --quiet` → OK
- `python -m compileall backend tools` → OK
- `xcodebuild FeedlingTest` → build succeeded (iOS 26.4 sim)
- `xcodebuild FeedlingBroadcast` → build succeeded
- Dry-run compose_hash for the new compose (with current
  `:78b51a6` image pin) = `0x1f0169bab4b1ee19058bd72bdb1fb46cc9b1b9de75a1e2a348134959c908efb9`.
  The real on-chain publish will use the compose bytes after CI
  pins a fresh image tag — don't pre-authorize this value.

**What still has to happen (fully CI-driven, two workflow_dispatch
runs — no manual `phala`/`gh`/`curl` on your laptop):**

1. Trigger `.github/workflows/bootstrap-prod9.yml` with `confirm=yes`.
   This single workflow:
   a. Asserts no stale `feedling-enclave-v2` CVM exists.
   b. Purges CF records for `api.feedling.app` + `mcp.feedling.app`
      (anything that would conflict with dstack-ingress's CNAME/TXT/CAA
      creation).
   c. Runs `phala deploy --node-id 18 --kms phala -e CF_*=$secret -j --wait`
      against the prod9 gateway; captures the new `app_id` + `vm_uuid`.
   d. Polls `https://<app-id>-5003s.<prod9-gateway>/attestation` and
      `https://api.feedling.app/healthz` + `https://mcp.feedling.app/sse`
      until all three respond (up to ~10 min for first-boot LE
      issuance).
   e. Publishes the new `compose_hash` on Eth Sepolia (idempotent).
   f. `gh variable set CVM_ID` → new `vm_uuid` so the next CI run
      on main updates *this* CVM in place.
   g. Auto-commits a one-line `CVMEndpoints.swift` bump
      (`defaultAppId` + `defaultGatewayDomain`) tagged `[skip ci]`.
2. Run `FEEDLING_CVM_APP_ID=<new> FEEDLING_CVM_GATEWAY_DOMAIN=dstack-pha-prod9.phala.network python3 tools/audit_live_cvm.py`
   → should be **8/8 green** (Row 8 = disclosure row since MCP TLS is
   now ingress-terminated).
3. Fresh iOS install on the one prod user's device → audit card
   should be **6/6 green**.
4. Trigger `.github/workflows/retire-prod5-vps.yml` with
   `confirm=yes-delete-prod5`. Safety-gated on `CVM_ID` already
   pointing at the new prod9 CVM. It:
   - `phala cvms delete <prod5-vm-uuid>` (billing stops).
   - SSH `openclaw@54.209.126.4` → `systemctl --user stop/disable/mask`
     the `feedling-backend` + `feedling-mcp` units and drops
     `~/RETIRED.md` tombstone.
   - Purges any CF records still pointing at 54.209.126.4.
   - Removes the `VPS_HOST`/`VPS_USER`/`VPS_DEPLOY_KEY` repo
     vars/secrets so no future CI run can reach the dead box.

**First-push footnote**: when this migration PR lands on `main`, the
existing `deploy-cvm` CI job will run and try `phala deploy --cvm-id
$CVM_ID` with `$CVM_ID` still pointing at the prod5 UUID. The on-chain
compose_hash publish runs FIRST and succeeds; only the final
`phala deploy` step fails (prod5 CVM can't boot a compose that targets
the prod9 gateway). That's expected red CI, not a problem — the hash
is already authorized, and `bootstrap-prod9.yml` is the intended next
step. Future pushes (after bootstrap flips `CVM_ID`) will go green.

**Key guardrails during migration**:

- `0x051a174f…` prod5 app_id still appears as defaults in
  `CVMEndpoints.swift` + `audit_live_cvm.py`. This is intentional so
  pre-cutover iOS builds keep working against the live pre-migration
  CVM. The CVM defaults flip happens in one commit after step 3 above.
- Compose_hash for the new compose depends on the image tag pinned in
  CI. The `deploy-cvm` job pins `:<sha>` and re-computes. Don't try to
  pre-authorize a hash by hand — you'll race the CI bump.
- `FEEDLING_MCP_TLS_IN_ENCLAVE=false` is the env-var seam that retires
  Phase C.2. Flipping it back would require re-adding ACME+
  `/var/run/dstack.sock` to the mcp service in compose; not just a
  redeploy.

## TL;DR

- **What's live (through Phase D, 2026-04-20)**: iOS app with end-to-end
  encrypted chat, memory, identity, agent nudges, and agent replies —
  **all write paths now wrap to v1 envelopes**; server disk is always
  ciphertext. Flask+MCP backend on `api.feedling.app`/`mcp.feedling.app`,
  plus a real Intel-TDX enclave on Phala Cloud that attests itself,
  terminates its own TLS on the attestation port (5003) with a
  dstack-KMS-bound cert AND on the MCP port (5002) with a real
  Let's Encrypt cert for `mcp.feedling.app` (private key provably inside
  the CVM via ACME-DNS-01 running at enclave boot), and hosts the decrypt
  proxy for agent reads.
- **CLI audit**: `tools/audit_live_cvm.py` → **8/8 green** against the live
  CVM. Checks `/attestation` parses, DCAP chain to Intel SGX Root CA,
  measurements non-zero + `mr_config_id[0]=0x01`, `compose_hash` authorized
  on FeedlingAppAuth (Eth Sepolia), RTMR3 event log + mr_config_id binding,
  live attestation-port TLS-cert-DER pinned to the attested fingerprint,
  and (Phase C.2) live MCP-port Let's Encrypt cert CA-verified for
  `mcp.feedling.app` with its pubkey SPKI sha256 pinned to the attested
  `mcp_tls_cert_pubkey_fingerprint_hex`. Pubkey fingerprint is stable
  across 90-day LE renewals because the key is derived from dstack-KMS
  at path `feedling-mcp-tls-v1` — cert rotates, key doesn't.
- **iOS audit card**: **6/6 green**. Screenshot:
  `docs/screenshots/audit_card_phase3_tls_pinned.png`.
- **Content-plaintext status**:
  - *Encrypted on server*: chat (iOS writer), memory add, identity init,
    `feedling.identity.nudge` (MCP decrypt-mutate-rewrap inside CVM),
    `feedling.chat.post_message` (MCP wraps to v1 envelope). **All write
    paths are now ciphertext at rest, and the backend rejects plaintext
    writes with 400.**
  - *SINGLE_USER + v0 strip*: shipped 2026-04-20 (task #23/#33). The
    single-user mode, `/v1/identity/nudge` HTTP endpoint, v0 plaintext
    branches in backend + MCP + enclave, `chat_bridge.py`, the silent
    iOS migration subsystem, and `/v1/content/rewrap` are all gone. The
    prod user data directory was wiped and she reinstalls fresh on
    multi-tenant. The in-place envelope-swap path for visibility toggles
    moved to `/v1/content/swap` (same validation shape, no v0 fallback).
  - *Phase D*: shipped 2026-04-20 (task #35). CVM on
    `ghcr.io/account-link/feedling:78b51a6` with compose_hash
    `0xd92bcd3cb1713ffe8e152417ab46e8179510c37ceed5ae6d423c586a2cd60049`
    authorized on Sepolia tx
    `0x235f0120d6982cbf8872e927ee2e59133627177ca9d3f862554d748ac6e60c7c`
    (block 10696873). CLI audit 8/8 green. VPS flat-layout data wiped
    same day (kept `.pepper` + APNs key). First deploy with no
    plaintext-write path anywhere in the backend.
  - *Prod user verified (task #36, 2026-04-20)*: the one real prod user
    did a fresh reinstall against multi-tenant on `:78b51a6`. iOS audit
    card went 8/8 green; chat / garden / identity all empty as expected
    post-wipe. During the verification I found 6 orphan users created
    server-side from a registration race in the iOS client — concurrent
    callers into `FeedlingAPI.ensureRegisteredIfCloud()` all passed the
    empty-api_key guard before any of them wrote back. Fixed in
    `93665cf` by serializing registration on an `@MainActor` Task
    mutex; orphan users + their data dirs were purged from the VPS
    (kept `usr_08a1cdac7e48a048`). Also hardened the VPS at the same
    time: `AuthKey_5TH55X5U7T.p8` chmod 600 (was 644), zombie
    `feedling-chat-bridge.service` disabled.
  - *CI post-strip*: `backend/test_api.py` rewritten to exercise v1
    envelopes end-to-end (plaintext POSTs now assert 400 rejection).
    Full suite green locally against a fresh multi-tenant backend.
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
- *Phase C part 2*: shipped 2026-04-20. ACME-DNS-01 runs inside
    the CVM at boot via `backend/acme_dns01.py` (no new deps —
    uses existing `cryptography` + `httpx`). Cert private key is
    derived from dstack-KMS at path `feedling-mcp-tls-v1`, so LE
    renewals (every 60 days via daily watchdog thread) don't
    rotate the pubkey — audit Row 8 stays green indefinitely.
    CF_ZONE_ID + CF_API_TOKEN injected via `phala deploy -e`
    (encrypted env channel, not in compose_hash). SNI quirk:
    Phala gateway routes by `-PORTs.*.phala.network` SNI, so
    Caddy uses the gateway hostname as upstream SNI with
    skip-verify; real trust root is the attestation. Task #30
    closed.
- *Phase B wave-2 shipped*: per-item visibility toggle on the
    memory garden (long-press context menu → "Hide from agent" /
    "Share with agent"; eye.slash indicator when local_only). The
    inline migration-progress row was stripped alongside the v0
    migration subsystem on 2026-04-20 — there's no legacy data left
    to re-wrap.
- *New doc `docs/MIGRATION.md`*: concrete three-option guide for
    the one real prod user to move from self-hosted VPS to
    Feedling Cloud's TEE-backed encryption. Linked from the
    in-app audit card.
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
    mechanism reveals, compose-hash consent modal copy. Source-of-truth
    files listed in "Before next agent picks this up" below.
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
10. Run `tools/audit_live_cvm.py` — all 8 rows should be green.

## How to update the VPS (non-enclave services)

```bash
SSH_KEY=/path/to/timeline-tuner-dashboard-dev.pem
ssh -i $SSH_KEY ubuntu@54.209.126.4 "sudo -iu openclaw bash -c '
    cd ~/feedling-mcp-v1 && git pull --ff-only origin main &&
    ~/feedling-mcp-v1/backend/.venv/bin/pip install -qr backend/requirements.txt &&
    pkill -f \"feedling-mcp-v1/backend/app.py\" &&
    pkill -f \"feedling-mcp-v1/backend/mcp_server.py\"'"
# systemd Restart=always brings them back.
# (chat_bridge.py + feedling-chat-bridge.service were retired in the
# 2026-04-20 SINGLE_USER/v0 strip — MCP feedling.chat.post_message
# replaces them.)
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
FEEDLING_DATA_DIR=/tmp/fl \
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
  userID yet), the extension now drops the frame (backend rejects
  non-v1 ingest post-strip).
- **iCloud Keychain on the broadcast extension**: extension reads its
  (non-secret) public keys from App Group; no secret keys live there.
  So iCloud Keychain sync applies only to the main app's
  `ContentKeyStore` / `KeyStore`, which is correct.
- **Deployer key rotation**: `FEEDLING_APP_AUTH` owner
  `0xa0eBcd26D7816D68a74b0CdC8037C16F8fcbF9C0` was the throwaway key
  used for Sepolia bring-up. Rotate before Base mainnet per
  `DEPLOYMENTS.md`.

## What's next (forward-looking)

### Phase E — Eth Sepolia → Ethereum mainnet  ← DEFERRED (do last)

**Status: DEFERRED** — per user direction 2026-04-20 ("Eth mainnet migration last").
**Pre-reqs:** Phase C part 2 stable ≥ 1 week; v0 strip done ✓; hardware wallet in hand; no open security bugs.

**Decision to confirm before starting:** Base mainnet (L2, ~100× cheaper gas, faster finality) vs Ethereum L1 mainnet (higher perceived trust). User said "Eth mainnet" — verify L1 vs L2 before spending gas.

**Steps (ready when pre-reqs met):**
1. Fresh deployer keypair on hardware wallet — current `0xa0eBcd…` is a throwaway (pasted in chat Apr 19 per `DEPLOYMENTS.md`).
2. Redeploy `FeedlingAppAuth.sol` to chosen mainnet; `forge verify-contract` on Etherscan/Basescan.
3. `addComposeHash` batch for all historical hashes (so old iOS builds still pass audit).
4. Update `backend/enclave_app.py` APP_AUTH defaults + iOS pinned contract address + chain_id.
5. Ship iOS release with new pinned address ~1 week before cutover.
6. Update `deploy/DEPLOYMENTS.md` with mainnet entry.

## Guardrails — don't touch without a plan

- WebSocket frame ingest (`/ws` in `backend/app.py`) — working, don't touch.
- APNs push (JWT + `.p8` key) — working, don't touch.
- `ScreenActivityAttributes.ContentState` fields — changing breaks live activities on installed builds.
- Phase 3 TLS derivation path (`feedling-tls-v1`) in `dstack_tls.py` — changing breaks existing pinned attestations.
- `/v1/content/swap` endpoint — used by iOS `flipMemoryVisibility`; don't rename.
- Any endpoint URL or response shape used by existing released builds — add new endpoints instead.
- VPS prod (`ubuntu@54.209.126.4`, `openclaw`) — coordinate changes with user; one real user's data lives here.

## Key reference files

| File | Purpose |
|---|---|
| `docs/DESIGN_E2E.md` | Master architecture doc (v0.3) |
| `docs/CHANGELOG.md` | Landmark diffs with dates |
| `deploy/DEPLOYMENTS.md` | Every deployed artifact on VPS + CVM + chain |
| `tools/audit_live_cvm.py` | Run after any enclave change — must be 8/8 before shipping |
| `docs/AUDIT.md` | Agent-consumable "is this safe?" guide |
| `DESIGN.md` | Design tokens + aesthetic — read before any UI change |

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
