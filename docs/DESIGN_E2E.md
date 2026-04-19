# Feedling End-to-End Encryption — Design Doc (v0.1)

Status: **draft, pre-implementation**
Owner: @sxysun
Target ship: after `NEXT.md` Steps 1–5 land in prod and multi-tenant is stable.
Companion doc: `docs/NEXT.md` (the plaintext multi-tenant backend this layers on top of).

---

## 1. Context & goals

Feedling now supports multi-tenant cloud hosting (see `NEXT.md`), but content
at rest is plaintext JSON. For the cloud product to be something users can
honestly feel safe handing personal chat / memories / screen frames to, we need
a privacy model that matches the claim *"Feedling cannot read your data."*

### 1.1 Goals

1. **Feedling-operator-zero-knowledge at rest.** Anyone with disk access,
   root, or SSH to Feedling infra sees ciphertext only for user content.
2. **Feedling-operator-zero-knowledge in flight.** Active requests cannot be
   inspected by a rogue Feedling operator with shell access; plaintext only
   ever materializes inside a hardware-attested TEE.
3. **SaaS Agent UX unchanged.** A user of Claude.ai, ChatGPT, Cursor, etc.
   pastes one string (the MCP connection URL with `?key=`) and is done. No
   private-key paste.
4. **User cryptographic ownership.** Private key material for content is
   generated on the iOS device and never leaves Keychain. The user can always
   decrypt their own content locally, even if Feedling disappeared.
5. **Per-item visibility control.** Users can mark individual memories / chats
   as *local-only*, preventing the Agent from ever reading them while keeping
   them readable in the iOS app.
6. **Verifiable software.** The enclave image is published on GitHub,
   reproducibly buildable, and its measurement is checked by each user's iOS
   device on every session.

### 1.2 Non-goals

- Protecting plaintext inside the Agent itself. When Claude.ai reads
  `feedling.chat.get_history`, Anthropic's servers receive plaintext — this is
  inherent to "using a SaaS Agent" and is not something Feedling can address
  cryptographically. Communicated to users clearly in onboarding.
- Reproducible iOS builds. Tracked as a separate workstream; in the interim
  users rely on published SHA-256 of IPAs + third-party audits.
- Protecting against a TDX hardware break. If Intel TDX is compromised at the
  hardware level, our guarantee degrades to "ciphertext at rest + TLS in
  flight." This is the same posture as every other TDX-based confidential
  service today.
- Key escrow / social recovery. Initial design: losing the phone without a
  backup means losing local read access (remote read via enclave continues to
  work). Phase 2 will add an optional iCloud Keychain backup flow.

---

## 2. Trust model

### 2.1 What a user must trust

| Component | Why | Mitigation if compromised |
|---|---|---|
| Intel TDX hardware + microcode | TEE isolation + attestation | Falls back to "ciphertext at rest"; still better than today's plaintext |
| Intel DCAP attestation chain | Verifying the attestation quote | Users can pin Intel's root cert; rotation requires app update |
| dstack base image | Hosts our app inside the CVM | Measurement is public & versioned by Phala |
| Feedling enclave image | Our code inside the TEE | Source on GitHub, reproducibly buildable, MRTD pinned by iOS |
| Apple iOS + Keychain | Holds user's content private key | Unavoidable for any iOS app; partially mitigable via published IPA hashes |
| Feedling's iOS binary | The verifier on the user's phone | Published SHA-256 + audit attestations; power users can self-host |

### 2.2 What a user no longer has to trust

- Feedling's non-TEE VPS and everything on it
- Feedling's root passwords, SSH keys, or bastion hosts
- Every current and future Feedling employee with infra access
- Disk backups, rsync mirrors, snapshot volumes
- Logs, metrics systems, or accidental `print()` statements in non-TEE code
- Anyone who compromises our non-TEE backend (short of breaking TDX)

### 2.3 Known asterisks (must be in onboarding)

1. **Your Agent sees plaintext.** Claude/ChatGPT/any SaaS Agent receives your
   data to do its job. Feedling cannot prevent this. For agent-side privacy,
   use a local Agent (Claude Desktop, Hermes, Ollama) or self-host entirely.
2. **Metadata is not encrypted.** Message timestamps, memory titles if you
   don't mark them `local_only`, APNs tokens, screen-frame timing, OCR token
   counts — these stay plaintext so the server can route pushes and do
   aggregation. If metadata-level privacy matters, self-host.
3. **App Store binary.** We publish the source and the IPA hash; third
   parties audit. Apple's signing chain is an unavoidable trust root for
   anyone using an iOS app from the App Store.

---

## 3. Cryptographic construction

All symmetric operations use **XChaCha20-Poly1305** via libsodium's
`crypto_secretbox_xchacha20poly1305`. All public-key operations use
**X25519 + XSalsa20-Poly1305** via libsodium's `crypto_box_seal` (anonymous
sealed box — sender is ephemeral, recipient is the known pubkey).

### 3.1 Key inventory

**Per-user, generated on iOS, never leaves the device:**

- `user_identity_sk` / `user_identity_pk` — Ed25519. Used to sign
  registration and rotation operations. Long-lived.
- `user_content_sk` / `user_content_pk` — X25519. Wraps per-item symmetric
  keys so iOS can always decrypt its own content locally. Long-lived.
- `user_api_key` — 32 random bytes, server-side stored as HMAC-SHA256 of the
  key with a per-server pepper. Revocable.

**Per-enclave deployment, generated inside the TEE at CVM boot:**

- `enclave_content_sk` / `enclave_content_pk` — X25519. Derived
  deterministically from dstack's KMS-bound seed + the string `"feedling-content-v1"`.
  Privkey never leaves the CVM memory; pubkey is published in attestation
  report data.
- `enclave_tls_cert` — standard TLS cert for `mcp.feedling.app`, issued by
  Let's Encrypt via ACME-DNS-01 from inside the CVM. Fingerprint published in
  attestation report data.
- `enclave_signing_sk` / `enclave_signing_pk` — Ed25519. Used to sign
  per-request decryption proofs (optional, for future auditability features).

**Per-content-item, generated on iOS at write time:**

- `K` — 32 random bytes. A fresh symmetric key for each content item.
- `nonce` — 24 random bytes. Used for the XChaCha20 encryption.

### 3.2 Content format

Every encrypted content item on disk at the Flask backend is a JSON object
with this shape. Plaintext metadata fields (id, ts, role, etc.) are listed to
clarify what the server does and does not see.

```jsonc
{
  "v": 1,                              // format version
  "id": "mom_abc123...",               // plaintext — server uses to dedupe/route
  "ts": 1744567890.123,                // plaintext — server uses for ordering, since-queries
  "role": "user",                      // plaintext — needed for long-poll filtering
  "source": "chat",                    // plaintext — metadata
  "visibility": "shared",              // "shared" (both user+enclave can decrypt) or "local_only" (user only)

  "body_ct": "base64(XChaCha20Poly1305(K, nonce, plaintext_body))",
  "nonce":   "base64(24 bytes)",
  "K_user":     "base64(crypto_box_seal(K, user_content_pk))",
  "K_enclave":  "base64(crypto_box_seal(K, enclave_content_pk))", // null when visibility=local_only
  "enclave_pk_fpr": "first 16 bytes hex of sha256(enclave_content_pk)"  // so we know which enclave keypair this was wrapped to; enables rotation
}
```

For frames (screen captures via WebSocket ingest):

```jsonc
{
  "v": 1,
  "filename": "frame_1744567890123.jpg",   // plaintext — server indexes on disk
  "ts": 1744567890.123,                    // plaintext
  "w": 1170, "h": 2532,                    // plaintext
  "app": "com.apple.Safari",               // PLAINTEXT in v1. See "Open Decision #4" in §11.

  "image_ct": "base64(XChaCha20Poly1305(K, image_nonce, jpeg_bytes))",
  "image_nonce": "base64(24 bytes)",
  "ocr_ct":    "base64(XChaCha20Poly1305(K, ocr_nonce, ocr_text))",
  "ocr_nonce": "base64(24 bytes)",
  "K_user":    "base64(crypto_box_seal(K, user_content_pk))",
  "K_enclave": "base64(crypto_box_seal(K, enclave_content_pk))",
  "enclave_pk_fpr": "…"
}
```

Size overhead per item: ~100 bytes of crypto + a few hundred bytes of base64
overhead. Negligible.

### 3.3 Why this construction

- **Independent recipients.** User and enclave each have their own long-lived
  keypair. Neither can derive the other's privkey. Compromise of one does not
  cascade.
- **Per-item symmetric key.** Rotating the enclave keypair requires only
  re-wrapping `K_enclave` values, not re-encrypting bodies. Cheap.
- **Sealed boxes (anonymous).** No sender keypair is needed — the iOS writer
  is implicitly authenticated by the API-key layer outside. Simpler key
  management.
- **Chosen libsodium primitives.** Misuse-resistant, widely audited, available
  on iOS (via Swift libsodium bindings) and Python (pynacl).
- **Local-only as first-class.** Setting `visibility=local_only` simply omits
  `K_enclave`. The server cannot distinguish "user forgot to encrypt to
  enclave" from "user intentionally kept it local" — enforced by iOS, visible
  to server as the explicit flag only for routing behavior (e.g. returning
  placeholder to the Agent).

---

## 4. Attestation protocol

### 4.1 What the enclave publishes

On CVM boot, the enclave generates its keypair(s) and TLS cert, then requests
a TDX quote from dstack's guest agent. The quote's `REPORT_DATA` field (64
bytes) is populated with:

```
REPORT_DATA = sha256( enclave_content_pk  ||
                      sha256(enclave_tls_cert_der)  ||
                      "feedling-v1" )
            || version_byte || flag_byte || reserved (14 bytes)
```

The quote is served at `https://mcp.feedling.app/attestation` as:

```jsonc
{
  "tdx_quote_b64": "...",                      // the raw TDX quote from Intel
  "enclave_content_pk_b64": "...",             // 32 bytes, X25519 pubkey
  "enclave_tls_cert_pem": "-----BEGIN CERT-----\n...",
  "enclave_signing_pk_b64": "...",             // 32 bytes, Ed25519 pubkey
  "enclave_release": {
    "git_commit": "abc123...",                 // commit hash of the enclave source
    "image_sha256": "...",                     // sha256 of the container image used by dstack
    "built_at": "2026-05-01T00:00:00Z"
  },
  "dstack_meta": {
    "base_image_measurement": "...",           // published by Phala
    "compose_hash": "..."
  }
}
```

This endpoint is unauthenticated and heavily cached (it only changes when the
enclave restarts).

### 4.2 iOS verifier logic

The iOS app ships with:

- **Intel SGX Root CA** certificate, pinned.
- **Accept-list of known-good `MRTD` measurements**, each annotated with the
  git commit, release date, and human-readable changelog.
- **Current "endorsed" dstack base image measurement** (updates via app
  release).

Pseudocode executed on every new session (cached for 24h between checks):

```swift
func verifyEnclave() throws -> (contentPk: Data, tlsCertFingerprint: Data) {
    // 1. Fetch the attestation bundle
    let bundle = try fetchAttestation("https://mcp.feedling.app/attestation")

    // 2. Verify TDX quote signature chain
    try IntelDCAP.verify(
        quote: bundle.tdx_quote_b64,
        rootCA: pinnedIntelRoot
    )

    // 3. Extract MRTD and RTMRs from the quote
    let mrtd = IntelDCAP.extractMRTD(bundle.tdx_quote_b64)
    let rtmrs = IntelDCAP.extractRTMRs(bundle.tdx_quote_b64)

    // 4. Check MRTD against accept-list
    if !acceptList.contains(mrtd) {
        throw .enclaveImageUnknown(mrtd, bundle.enclave_release)
        // iOS UI: show review card with diff link to bundle.enclave_release.git_commit
    }

    // 5. Verify REPORT_DATA binds the published pubkey + cert
    let reportData = IntelDCAP.extractReportData(bundle.tdx_quote_b64)
    let expected = SHA256(
        bundle.enclave_content_pk +
        SHA256(bundle.enclave_tls_cert_der) +
        "feedling-v1"
    )
    guard reportData.prefix(32) == expected else {
        throw .reportDataMismatch
    }

    // 6. Cache
    try trustStore.pin(
        mrtd: mrtd,
        enclaveContentPk: bundle.enclave_content_pk,
        tlsCertFingerprint: SHA256(bundle.enclave_tls_cert_der),
        expires: .now + 24.hours
    )

    return (bundle.enclave_content_pk, SHA256(bundle.enclave_tls_cert_der))
}
```

TLS connections to `mcp.feedling.app` use a custom `ServerTrust` evaluator:
the presented cert's SHA-256 fingerprint must match the one pinned by
`verifyEnclave`. Standard Let's Encrypt CA verification is still done — TEE
attestation is additive, not replacing PKI.

### 4.3 MRTD review UX

When the iOS accept-list does not contain the server's current `MRTD`:

```
┌───────────────────────────────────────────────────┐
│  🔒 Feedling's hardware enclave has updated       │
│                                                   │
│  New code was deployed. To continue, review:      │
│                                                   │
│  Old version:  a1b2c3d4 (2026-04-15)              │
│  New version:  e5f6a7b8 (2026-05-01)              │
│  Changes:      Fixed APNs retry logic, no changes │
│                to cryptographic primitives.       │
│                                                   │
│  [ View diff on GitHub ]                          │
│  [ View enclave source ]                          │
│  [ Pause updates for now ]                        │
│                                                   │
│  [     Approve and continue     ]                 │
└───────────────────────────────────────────────────┘
```

Tap Approve → MRTD added to accept-list, session proceeds. Tap Pause → app
falls back to local-only mode (iOS shows data from local cache, writes queue
up, Agent queries silently degrade).

For most releases we pre-ship the upcoming MRTD in the iOS binary. Users who
auto-update both apps together never see this prompt. The prompt is the
failsafe when infra moves ahead of iOS, or when a user has rejected a prior
update.

---

## 5. Core data flows

### 5.1 Registration

```
iOS                                     Flask                    Enclave CVM
 │                                        │                          │
 │  generate user_identity_kp             │                          │
 │  generate user_content_kp              │                          │
 │  store privkeys → Keychain             │                          │
 │                                        │                          │
 │  fetchAttestation ─────────────────────┼──────────────────────────►
 │◄── attestation bundle ─────────────────┼────── (via Caddy TCP) ────┤
 │  verifyEnclave()                       │                          │
 │                                        │                          │
 │  POST /v1/users/register               │                          │
 │  {identity_pk, content_pk, sig} ──────►│                          │
 │                                        │  hash api_key, store     │
 │                                        │  {user_id, identity_pk,  │
 │                                        │   content_pk, created_at}│
 │◄── {user_id, api_key} ─────────────────┤                          │
 │                                        │                          │
 │  store api_key → Keychain              │                          │
 │  sync apiKey → app group               │                          │
```

The enclave is not involved in registration. It doesn't need to be: Flask
stores the user's public keys; the enclave only needs its own keypair plus
access to Flask to do decrypt-on-read. This keeps the TEE code minimal.

### 5.2 Content write (chat message example)

```
iOS                                     Flask
 │                                        │
 │  plaintext = "hello agent"             │
 │  K = random(32)                        │
 │  nonce = random(24)                    │
 │  body_ct = XChaCha20Poly1305(K, nonce, │
 │             plaintext)                 │
 │  K_user = box_seal(K, user_content_pk) │
 │  K_enclave = box_seal(K,               │
 │              enclave_content_pk)       │
 │                                        │
 │  POST /v1/chat/message ───────────────►│
 │  { v: 1,                               │  append to
 │    role: "user",                       │  <uid>/chat.json
 │    ts: <now>,                          │  verbatim
 │    visibility: "shared",               │  (never decrypts)
 │    body_ct, nonce,                     │
 │    K_user, K_enclave,                  │
 │    enclave_pk_fpr }                    │
 │◄── {id, ts} ───────────────────────────┤
```

Flask changes:

- Request body validator now requires the `v`, `body_ct`, `nonce`, `K_user`,
  `enclave_pk_fpr` fields. `K_enclave` required unless `visibility == "local_only"`.
- Flask does not attempt to base64-decode or inspect these fields. They are
  opaque.
- Legacy plaintext write path (`content` field) is kept behind a deprecation
  header for the migration window (see §8).

### 5.3 Content read by Agent via MCP

```
Claude.ai                 Caddy          Enclave CVM                      Flask
  │                         │                │                              │
  │   TLS:                  │ TCP pass-      │                              │
  │   GET /sse?key=xxx ────►│ through ──────►│                              │
  │                         │ (SNI only)     │  TLS terminates HERE          │
  │◄─ event: endpoint …  ───┤◄───────────────┤                              │
  │                         │                │                              │
  │   POST /messages/?...   │                │                              │
  │   feedling.chat.get_... ├───────────────►│                              │
  │                         │                │  check api_key               │
  │                         │                │  (fetch users.json) ────────►│
  │                         │                │◄─ user record ───────────────┤
  │                         │                │                              │
  │                         │                │  fetch chat ciphertexts ────►│
  │                         │                │◄─ <uid>/chat.json ───────────┤
  │                         │                │                              │
  │                         │                │  for each item:              │
  │                         │                │    if visibility=local_only: │
  │                         │                │      content = null          │
  │                         │                │    else:                     │
  │                         │                │      K = box_seal_open(      │
  │                         │                │         K_enclave,           │
  │                         │                │         enclave_content_sk)  │
  │                         │                │      body = XChaCha20Poly…   │
  │                         │                │             open(K, nonce,   │
  │                         │                │                  body_ct)    │
  │                         │                │                              │
  │                         │                │  format MCP JSON response    │
  │◄── plaintext via TLS ───┤◄───────────────┤  write to SSE stream         │
  │                         │                │  (TLS encrypts inside)       │
```

Plaintext exists in two places:

1. Inside the enclave's memory (TDX-protected — unobservable from outside).
2. In the TLS wire stream to Claude.ai after it leaves our infra.

It does **not** exist in Caddy's memory, in the host OS buffers, on any disk,
in any log. This is the Option 2.5 property.

### 5.4 Rotation

**User content key rotation:** iOS generates a new `user_content_kp`, signs a
rotation message with `user_identity_sk`, uploads the new pubkey. Old content
items remain readable by iOS (still has old privkey) but new writes use the
new key. Optionally, iOS can re-wrap old `K_user` values in background.
Server cannot help with this — it has no plaintext.

**Enclave content key rotation:** Tied to enclave image deploys. New
deployment → new MRTD → new `enclave_content_kp` (deterministic from
dstack-KMS + new measurement seed). Process:

1. New CVM starts alongside old CVM, publishes new attestation.
2. iOS apps begin verifying new MRTD. Pre-shipped MRTD in iOS → silent; new
   MRTD → review prompt.
3. iOS, upon accepting new MRTD, kicks off a per-user re-wrap: fetches items
   needing re-wrap (server returns items whose `enclave_pk_fpr` differs from
   the new enclave's), unseals `K_user` locally, re-seals `K` to new
   `enclave_content_pk`, uploads re-wraps via `POST /v1/content/rewrap`.
4. During re-wrap, reads of not-yet-rewrapped items by the new enclave return
   `{content: null, rewrap_pending: true}` — agent sees a placeholder
   gracefully; iOS UI sees them normally (has own key).
5. Old CVM kept alive until re-wrap completion drops below X%, then retired.

The key property: **the re-wrap authority is iOS, not the old enclave.** This
means enclave-image changes can't secretly smuggle forward access — iOS
controls whether to bless the new enclave by re-wrapping, and it only does so
after explicit user approval (unless pre-shipped in app).

### 5.5 Migration from today's plaintext data

Users whose accounts were created under the current plaintext multi-tenant
mode need a one-time upgrade. Server changes:

- New endpoint: `POST /v1/users/upgrade` — accepts the user's pubkeys,
  returns a one-time `upgrade_token` valid for 1 hour.
- New endpoint: `GET /v1/upgrade/plaintext?token=<upgrade_token>` — returns
  all plaintext data for this user in a single stream (chat, memory,
  identity, frames metadata + OCR). Consumed only during migration.
- New endpoint: `POST /v1/upgrade/ciphertext?token=<upgrade_token>` — accepts
  bulk ciphertext re-upload. Swaps storage atomically.
- After successful migration, user record flag `upgraded_to_v1=true` and all
  legacy plaintext endpoints reject writes for that user.

iOS migration flow (triggered on first launch after E2E update):

```
1. Generate keypairs.
2. Verify enclave attestation.
3. POST /v1/users/register OR POST /v1/users/upgrade (depending on whether
   the user already exists).
4. If upgrade:
   a. Fetch plaintext dump from /v1/upgrade/plaintext
   b. For each item: encrypt with a fresh K, wrap K to (user_pk, enclave_pk).
   c. POST /v1/upgrade/ciphertext with the bundle.
   d. Show progress UI: "Encrypting your memories… 43/127"
5. Mark local state migrated=true.
```

The plaintext dump briefly materializes plaintext on iOS during step 4 —
that's fine, iOS is trusted. It never touches Feedling's infra after that.

---

## 6. Component architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ feedling.app VPS (non-TEE Ubuntu box, any cloud)                 │
│                                                                  │
│   Caddy 2 :443                                                   │
│     ├── api.feedling.app   → reverse_proxy :5001 (TLS terminates │
│     │                         in Caddy, plaintext fine because   │
│     │                         all POSTs are ciphertext already)  │
│     └── mcp.feedling.app   → layer4 pass-through :5002            │
│                               (SNI routing only; TLS to CVM)     │
│                                                                  │
│   Flask :5001                                                    │
│     stores opaque ciphertext blobs                               │
│     handles identity-pubkey registration, api_key hash store     │
│                                                                  │
│   Nothing else runs as root on this host. Minimal surface.       │
└──────────────────────────────────────────────────────────────────┘
                        │                          │
                        │ (internal HTTPS)         │ (TCP)
                        ▼                          │
┌──────────────────────────────────────────────────▼───────────────┐
│ dstack CVM (Intel TDX, separate host or Phala network)           │
│                                                                  │
│   rustls TLS :5002                                               │
│     cert: Let's Encrypt (ACME-DNS-01 from inside CVM)            │
│     privkey: sealed in CVM, never persisted outside TEE          │
│                                                                  │
│   FastMCP SSE server :5002                                       │
│     14 tools as today; handlers now decrypt before returning     │
│                                                                  │
│   Decryption oracle                                              │
│     enclave_content_sk (derived from dstack KMS + MRTD)          │
│     box_seal_open + XChaCha20Poly1305                            │
│                                                                  │
│   Attestation server (read-only)                                 │
│     GET /attestation → tdx_quote + pubkeys + release info        │
│                                                                  │
│   HTTP client to Flask (internal)                                │
│     fetches ciphertext blobs as needed                           │
└──────────────────────────────────────────────────────────────────┘
```

Why split Flask out of the TEE:

1. Flask never touches plaintext. Putting it in the TEE adds TCB without
   adding security.
2. Disk I/O, persistent state, and WebSocket ingest are operationally easier
   outside a CVM.
3. Crashing Flask doesn't crash the TEE; CVM reboot cycles are independent.

Why not put Caddy in the TEE:

- Caddy is thousands of lines, well-known-good, not touching plaintext. Don't
  bloat the TCB.
- TLS pass-through mode for `mcp.feedling.app` means Caddy never decrypts —
  it's looking at SNI ClientHello extensions only, then forwarding encrypted
  bytes.

---

## 7. iOS responsibilities (summary)

1. **Keypair lifecycle.** Generate, store in Keychain with
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Optionally export as
   encrypted mnemonic for backup (phase 2).
2. **Attestation verifier.** Ship with pinned Intel root CA, accept-list of
   MRTDs, dstack base image measurements. Run DCAP verification on each
   session-start.
3. **Content encryption before any upload.** Every field that leaves the
   phone destined for storage goes through the sealed-box-to-both path.
4. **Migration executor.** When enclave MRTD changes, handle re-wrap.
5. **Local decrypt path.** Chat / Identity / Memory Garden views decrypt
   directly on-device; they do not round-trip through the enclave.
6. **Local-only flag UI.** A "private memory" toggle on memory-add and a
   global default in Settings.

### 7.1 iOS dependencies (new)

- `swift-sodium` (libsodium bindings) — content encryption.
- `SwiftDCAP` or custom Swift wrapper around Intel's DCAP verify library —
  attestation verification. (Need to evaluate available libraries; may need
  to port.)

---

## 8. Phased implementation plan

Each phase is independently ship-able and does not break users on the
previous phase.

### Phase 1 — TEE infrastructure (1–2 weeks)

- [ ] Pick TDX deployment target (see Open Decision #1).
- [ ] Dockerfile + reproducible build for the enclave app.
- [ ] Minimal dstack deployment: just `/attestation` endpoint + key derivation.
- [ ] iOS: add libsodium, add attestation verifier, pin first MRTD.
- [ ] E2E smoke test: iOS app fetches attestation, verifies, displays "🔒
      Verified: dstack CVM image abc123" in Settings.

**Exit criterion:** iOS can verify the enclave is running published code. No
content encryption yet.

### Phase 2 — Content encryption, backend still serves plaintext-compatible (2 weeks)

- [ ] Define and implement content format (§3.2) on iOS: wrap each write.
- [ ] Flask: accept both plaintext (legacy) and ciphertext (v1) forms; store
      both formats side-by-side during migration window.
- [ ] Enclave: implement `/v2/*` tool handlers that decrypt before returning.
- [ ] MCP server: start routing v2-marked users through enclave, v1 users
      through legacy Flask-direct path.
- [ ] iOS: Migration UI — one-time re-encrypt flow.

**Exit criterion:** A fresh iOS install writes ciphertext, Agent reads
plaintext via enclave; existing users can upgrade on demand.

### Phase 3 — MCP in TEE + TLS termination (1 week)

- [ ] Move FastMCP into the CVM. Configure rustls for `mcp.feedling.app`.
- [ ] Caddy config: change `mcp.feedling.app` from `reverse_proxy` to
      `layer4 tls passthrough`.
- [ ] ACME-DNS-01 plumbing so the CVM can auto-renew certs without exposing
      the privkey.
- [ ] Audit: confirm no plaintext path leaves the CVM.

**Exit criterion:** Even Feedling ops with root on the non-TEE host cannot
observe live plaintext.

### Phase 4 — User-facing privacy UI (1 week)

- [ ] Settings → Privacy section:
      - Enclave status (MRTD, git commit, verified-at timestamp)
      - Per-item local-only default toggle
      - Export / backup keys (phase-2 lite: encrypted mnemonic QR code)
- [ ] Migration status view.
- [ ] MRTD change review card.
- [ ] Onboarding copy: the three asterisks (§2.3) in plain language.

**Exit criterion:** A user can open the app, see the privacy state concretely,
and decide whether to approve updates.

### Phase 5 — Production cutover (spread)

- [ ] Migrate prod users in batches.
- [ ] Retire plaintext endpoints (phase out over 30 days).
- [ ] Update website / product copy to reflect new guarantees.

Total calendar time: **~6 weeks** for a clean, audit-ready implementation.

---

## 9. Threat model

### 9.1 Adversaries we defend against

| Adversary | Attack | Defense |
|---|---|---|
| Network passive | Sniff traffic | TLS everywhere, TEE-terminated for MCP path |
| Network MITM | Hijack DNS, inject CA | TLS pinning of enclave cert via attestation |
| Feedling disk breach | Dump `feedling-data/` | Data at rest is ciphertext; key material only inside TEE or on user phones |
| Feedling operator | Read files, attach gdb to processes | Non-TEE process never has plaintext; TEE inaccessible from host |
| Feedling rogue dev | Push code change to read data | MRTD change triggers iOS review prompt; cannot be silent |
| Feedling VPS root compromise | Full host access | Same as rogue operator — TEE isolation holds |
| Physical theft of VPS disk | Cold boot of drive | Ciphertext only |
| Compromised Agent | Agent-side exfil | Out of scope — any data the Agent is authorized to read can be exfiltrated by a compromised Agent. Limit blast radius with per-item local-only. |
| Lost / stolen iOS device | Attacker has phone | Keychain requires device passcode / biometrics post-first-unlock; api_key remotely revocable via a different device |

### 9.2 Adversaries we do NOT defend against

| Adversary | Why | Mitigation |
|---|---|---|
| Intel TDX hardware break | We run on top of TDX | Fall back to "ciphertext at rest + TLS in flight" — still better than most SaaS |
| Malicious iOS update that we ship | We sign iOS builds | Published IPA hashes, third-party audit, self-host escape hatch |
| Malicious Agent (Anthropic, OpenAI etc.) | Agent receives plaintext to function | Use local Agent for agent-side privacy |
| User's compromised phone | Malware with Keychain access | Standard iOS threat model; users should lock device, update iOS |
| State-level actor targeting specific users | TDX side-channels, social eng., legal process | Beyond product scope |

---

## 10. Operational concerns

### 10.1 Debugging

We lose the ability to `cat chat.json` in prod. Mitigations:

- **Structured metadata logging.** Log non-content fields aggressively
  (timestamps, user_ids, token counts, error codes). Often enough to
  diagnose.
- **User opt-in debug mode.** A user can temporarily grant us decrypt access
  for a specific item by uploading a re-wrap to a Feedling-staff pubkey.
  Explicit, auditable, user-initiated only.
- **Synthetic test accounts.** E2E flow should be testable end-to-end on a
  staging user whose data is freely inspectable because we control the
  phone.

### 10.2 Disaster recovery

- **Flask data:** ciphertext backups are fine to store in S3 / wherever;
  nobody can read them without a user's iOS device.
- **Enclave keys:** deterministic from dstack KMS + MRTD. To restore, redeploy
  the same image. Data re-encrypted under the same MRTD is still readable.
- **User iOS device loss:** if we implement Phase-2 Keychain export, user
  restores from iCloud. Otherwise, their local read access is lost, but the
  enclave path (remote Agent reads) keeps working indefinitely via the
  stored api_key.

### 10.3 Cost

- dstack / TDX CVM: ~$40–$100/month for a small instance, depending on
  deployment target.
- Additional TCP bandwidth for TLS pass-through: negligible.
- Engineering time: ~6 weeks as laid out.

---

## 11. Open decisions (need sign-off before Phase 1)

1. **TDX deployment target.** Options:
   a. Phala mainnet (fully decentralized, attestation is public).
   b. GCP Confidential VM (easy, matches rest of likely infra).
   c. Azure Confidential Computing (similar).
   d. Bare metal TDX server in a colo (most control, highest ops cost).
   → My recommendation: **(b) GCP Confidential VM** for simplicity now, keep
     Phala option open for a future "decentralized tier."

2. **MRTD pre-approval policy.** How often are we willing to ship iOS updates
   just to bump an accept-list? Proposal: batch enclave updates with iOS
   releases monthly; emergency patches trigger an MRTD review prompt,
   justified by the diff.

3. **Local-only default.** Ship with default `visibility=shared` (Agent can
   read all memories unless user flips) or default `local_only`?
   Recommendation: **default shared** — otherwise Agent experience degrades
   silently. Make local-only a clear opt-in per item.

4. **Frame `app` field.** Current design keeps the foreground app bundle ID
   plaintext (so server can do per-app aggregation). This leaks that the
   user was in, e.g., Signal. Do we encrypt it?
   Recommendation: encrypt it. `/v1/screen/analyze` can run in the enclave if
   needed, or move its per-app aggregation into the iOS client.

5. **OCR-less semantic analysis.** `_semantic_analysis()` currently reads OCR
   text plaintext. Under E2E:
   a. Move the classifier to iOS; upload only the resulting tag
      (`semantic_scene: ecommerce_choice_paralysis`).
   b. Run the classifier inside the enclave.
   → Recommendation: **(a)**. The classifier is 30 lines of keyword matching.
      Pushing it to iOS keeps the enclave TCB smaller. iOS uploads the tag
      plaintext (metadata class — we already accept that) and no raw OCR.

6. **Identity-dim values.** These are integers 0–100, tiny. Encrypting them
   costs nothing but prevents stats/aggregation. Probably encrypt.

7. **Backup story timeline.** Phase 2 adds mnemonic-based iCloud Keychain
   backup. Before shipping Phase 5, we need this — otherwise users who lose
   their phone before backing up lose local access. (Remote via enclave
   still works, so the situation isn't catastrophic, but is worth
   communicating.)

---

## 12. What we will tell users

Proposed marketing / onboarding copy, to be iterated:

> **Feedling's privacy guarantee, exactly.**
>
> Your chats, memories, identity card, and screen captures are encrypted on
> your iPhone before they ever leave your device. Feedling's servers hold
> your data as ciphertext blobs that our employees, our servers, and anyone
> who breaches us cannot read.
>
> When your Agent (Claude, ChatGPT, etc.) needs to read your data, it
> happens inside a hardware-isolated secure enclave whose exact code is
> published on GitHub. Your iPhone cryptographically verifies this enclave
> every time it opens a session. If we ever change what the enclave does,
> your iPhone will notice and ask you to review the change.
>
> Two honest caveats:
>
> 1. **Your Agent sees plaintext by design.** When you ask Claude to read
>    your memories, Claude needs to read them to help you. Anthropic's
>    servers handle that plaintext. This is true of every AI assistant that
>    can read your data, and Feedling can't change it. For the strictest
>    privacy, use a local Agent (Claude Desktop, Hermes).
>
> 2. **iOS app verification relies partly on Apple.** We publish every
>    binary's hash, and security researchers verify them independently. If
>    that's not enough, Feedling is open source — you can self-host the
>    entire stack. Our SKILL.md has a runbook any agent can follow to
>    deploy Feedling to your own VPS.
>
> Everything else — our VPS, our database, our logs, our employees with
> SSH access — cannot read your data. That's the whole design.

---

## 13. References

- `docs/NEXT.md` — prerequisite multi-tenant backend this layers on top of.
- `skill/SKILL.md` — self-hosted runbook for users who prefer that over TEE.
- Intel TDX attestation spec: <https://cdrdv2-public.intel.com/726790>
- dstack framework: <https://github.com/Dstack-TEE/dstack>
- dstack tutorial (@amiller): <https://github.com/amiller/dstack-tutorial>
- libsodium sealed boxes: <https://doc.libsodium.org/public-key_cryptography/sealed_boxes>
- Apple CryptoKit Curve25519: <https://developer.apple.com/documentation/cryptokit/curve25519>

---

## 14. Change log

- v0.1 (2026-04-19): initial draft. Owner: @sxysun. Pending review +
  decisions on §11 open questions before Phase 1 starts.
