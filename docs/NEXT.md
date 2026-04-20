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
| Phase C.3 | `identity.nudge` v1 decrypt-mutate-rewrap in MCP; `chat.post_message` wraps to v1 | `cc329a8` |
| Docs | `AUDIT.md`, `MIGRATION.md`, `DESIGN.md`, `PHASE_B_PLAN.md`, GitHub footer links | `3a4acf5` |

CLI auditor `tools/audit_live_cvm.py`: **8/8 green**.
iOS audit card: **6/6 green** (with 8th row: MCP-port TLS bound to attestation).
Current CVM image: `ghcr.io/account-link/feedling:cc329a8`.

---

## What's still open, in priority order

### 1 — Phase C part 2: ACME-DNS-01 inside the enclave  ← BLOCKED on DNS token

**Status: BLOCKED**  
**Blocker:** needs Cloudflare (or Namecheap) `dns:edit` API token for the `feedling.app` zone.

**Why this matters:** Right now `mcp.feedling.app` (what Claude.ai connects to) goes:
```
Claude.ai  ──HTTPS──►  Caddy on VPS  ──HTTP──►  dstack-gateway  ──►  enclave port 5002
```
Caddy holds the TLS private key for `mcp.feedling.app`. That key lives on the VPS, not inside the TDX boundary. So there's still a "trust Caddy" step in the MCP path that the attestation model can't close.

**Goal:** The TLS private key for `mcp.feedling.app` is generated inside the CVM and never leaves it. Claude.ai connects end-to-end-attested.

**Chosen approach (Phase C plan option c):**
```
Claude.ai  ──HTTPS──►  Caddy (layer4 SNI passthrough, no termination)
                           ──raw TLS bytes──►  dstack-gateway (-5443s. suffix)
                               ──raw TLS bytes──►  enclave port 443
                                   ──TLS terminates inside CVM──►  MCP/uvicorn
```

Caddy runs in pure TCP proxy mode for `mcp.feedling.app` — it can't see the plaintext because it never terminates TLS. The enclave holds a Let's Encrypt cert obtained via ACME-DNS-01, issued to the `mcp.feedling.app` domain, with private key generated and stored only in CVM RAM.

**Implementation plan (ready to execute when DNS token arrives):**

#### Step 1 — Add ACME-DNS-01 client inside the enclave (backend/)
```
backend/
  acme_dns01.py      # new — thin wrapper around `acme` Python lib + Cloudflare DNS API
```

`acme_dns01.py` logic:
```python
# 1. Generate EC P-256 key in memory (never written to disk)
# 2. Submit CSR to Let's Encrypt ACME v2 for mcp.feedling.app
# 3. For DNS-01 challenge: write TXT _acme-challenge.mcp.feedling.app via CF API
# 4. Poll for propagation, respond to challenge
# 5. Delete TXT record
# 6. Store cert PEM in memory; renew 30 days before expiry (certs are 90-day)
# 7. Expose cert bytes as module-level `get_mcp_cert() -> (cert_pem, key_pem)`
```

Required packages (add to `requirements.txt`):
- `acme>=2.10` (Let's Encrypt ACME client)
- `cloudflare>=3.1` (or `requests` + raw CF REST API — no SDK dependency)
- `cryptography>=42` (already present for dstack_tls.py)

Environment variables (add to `deploy/docker-compose.phala.yaml` mcp service):
```yaml
FEEDLING_ACME_DOMAIN: "mcp.feedling.app"
FEEDLING_ACME_EMAIL: "sxysun9@gmail.com"
FEEDLING_CF_API_TOKEN: "${CF_API_TOKEN}"   # injected as Phala secret
FEEDLING_ACME_STAGING: "false"             # set true to test against LE staging first
```

#### Step 2 — Modify mcp_server.py TLS startup
Currently `_materialize_tls_cert()` uses the dstack-KMS self-signed cert.

Replace with:
```python
async def _acquire_mcp_tls():
    if os.getenv("FEEDLING_ACME_DOMAIN"):
        return await acme_dns01.get_or_renew()    # Let's Encrypt cert
    return _materialize_tls_cert()                 # fallback: dstack-KMS self-signed
```

Uvicorn startup:
```python
uv_config = uvicorn.Config(app, host="0.0.0.0", port=443,
                            ssl_certfile=cert_path, ssl_keyfile=key_path)
```

Port 443 inside the container — maps to exposed port via `-443s.` Phala passthrough suffix.

#### Step 3 — Caddy config change on VPS

Replace the existing `mcp.feedling.app` reverse_proxy block with layer4 SNI passthrough:

```caddyfile
# Current (REMOVE):
# mcp.feedling.app {
#     reverse_proxy https://<phala>-5002s....
# }

# New (ADD to Caddyfile top-level, outside any site block):
{
    layer4 {
        mcp.feedling.app:443 {
            @tls tls
            route @tls {
                proxy {
                    upstream <phala-mcp-url>-443s.<hash>.phala.network:443
                }
            }
        }
    }
}
```

This requires the `layer4` module: `xcaddy build --with github.com/mholt/caddy-l4`.

Alternative if recompiling Caddy is undesirable: run a separate `nginx` stream block (TCP proxy mode) specifically for `mcp.feedling.app:443`. Nginx stream config is simpler:
```nginx
stream {
    server {
        listen 443;
        proxy_pass <phala-mcp-url>-443s.<hash>.phala.network:443;
    }
}
```
This is the lower-friction path. **Recommend nginx stream over Caddy recompile.**

#### Step 4 — Update audit card and CLI auditor

`AuditCardView.swift` Row 8 (`mcpTlsBinding`) currently shows:
> "MCP port TLS bound to attestation — self-signed dstack-KMS cert, fingerprint in attestation bundle"

Update copy to:
> "MCP TLS: Let's Encrypt cert — private key generated inside CVM, never exported"

Mechanism disclosure update — also note: because LE cert changes on renewal, we can no longer pin the fingerprint directly. Instead the audit card shows:
- cert is issued to `mcp.feedling.app` (verifiable by hostname)
- cert is CA-signed by Let's Encrypt (verifiable by chain)
- private key was generated inside the CVM (verifiable by attestation attestation — the `report_data` field includes `sha256(tls_pubkey)`)

The `build_report_data()` in `enclave_app.py` already includes `tls_cert_fingerprint_hex` in `report_data`. For the MCP ACME cert, the enclave must also include `sha256(mcp_cert_pubkey)` in `report_data` so iOS/CLI can verify the binding:

```python
# enclave_app.py build_report_data()
report_data = sha256(
    attestation_tls_pubkey_bytes +   # existing
    mcp_acme_pubkey_bytes            # new — bytes of LE cert public key
)
```

CLI auditor `tools/audit_live_cvm.py` Row 8 update: connect TLS to `mcp.feedling.app:443`, verify cert is issued to that hostname, then verify `sha256(cert.pubkey)` matches `attestation.mcp_cert_pubkey_hash`.

#### Step 5 — Renewal loop
ACME certs expire every 90 days. Add a background thread in `mcp_server.py`:
```python
async def _renewal_loop():
    while True:
        await asyncio.sleep(24 * 3600)   # check daily
        if acme_dns01.needs_renewal():   # 30-day threshold
            new_cert, new_key = await acme_dns01.get_or_renew(force=True)
            await uvicorn_server.restart_with_new_cert(new_cert, new_key)
```

Uvicorn doesn't support hot cert reload natively — easiest approach: on renewal, write new cert to a tempfile pair and send `SIGHUP` to the uvicorn process (or restart the MCP service container; Phala CVM services restart in <5s).

#### Step 6 — Test plan
1. **Staging run first**: set `FEEDLING_ACME_STAGING=true`, deploy, verify Let's Encrypt staging cert is obtained and `mcp.feedling.app` is reachable from Claude.ai (staging certs trigger browser warning but prove the flow works).
2. **Production run**: set `FEEDLING_ACME_STAGING=false`, redeploy.
3. **CLI auditor**: `python tools/audit_live_cvm.py` → Row 8 green with updated cert-pubkey binding check.
4. **iOS audit card**: tap Row 8, verify it shows "Let's Encrypt, key inside CVM."
5. **Renewal test**: manually set expiry threshold to 89 days, confirm renewal triggers within 24h.

**DNS token scope needed:**  
Cloudflare: create an API token with `Zone:DNS:Edit` permission scoped to only the `feedling.app` zone. Full account tokens are unnecessary and unsafe.

**To start:** provide the token and this plan executes. No other blockers.

---

### 2 — Task #23: Strip v0 code paths  ← DEFERRED

**Status: DEFERRED** — waiting for the one prod user (sxysun's friend, VPS SINGLE_USER=true) to install the updated iOS app and complete silent migration. `docs/MIGRATION.md` has her three options.

**What to strip once her migration completes:**
- `backend/app.py`: remove `POST /v1/chat/message` plaintext branch, `POST /v1/memory/add` plaintext branch, `POST /v1/identity/init` plaintext branch, `POST /v1/content/rewrap` endpoint itself, `_rewrap_chat()`, `_rewrap_memory_inplace()`, `_rewrap_identity()`.
- `backend/mcp_server.py`: remove v0 fallback branches in `memory_add_moment`, `chat_post_message`, `identity_init`.
- iOS `FeedlingAPI.swift`: remove v0 read/decode branches (the `if envelope == nil` fallback paths in the fetch/decode functions).
- iOS `FeedlingAPI.swift`: remove `runSilentV1MigrationIfNeeded()` itself and the `feedling.v1MigrationDone.*` UserDefaults key (after confirming migration ran once on all installed instances).
- All `v0` references in `docs/DESIGN_E2E.md`.

**Exit criterion:** `grep -r "v0\|plaintext\|rewrap" backend/` returns only comments; server never stores unencrypted content.

---

### 3 — Phase D: Eth Sepolia → Ethereum mainnet  ← DEFERRED (do last)

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
