# Feedling End-to-End Encryption — Design Doc (v0.3)

Status: **v0.3 — decisions locked, pre-implementation**
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
| Feedling enclave image | Our code inside the TEE | Source on GitHub, reproducibly buildable, `compose_hash` authorized via on-chain `AppAuth` contract on Base (dstack KMS enforces) |
| Base L2 consensus | Append-only record of authorized `compose_hash` values | Compromise requires breaking Base — same security model as any L2-anchored app |
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
  "owner_user_id": "usr_abc…",         // plaintext — bound into AEAD additional-data (see §3.4)

  "body_ct": "base64(XChaCha20Poly1305(K, nonce, plaintext_body, aad=owner_user_id||v||id))",
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

  "owner_user_id": "usr_abc…",
  "image_ct": "base64(XChaCha20Poly1305(K, image_nonce, jpeg_bytes, aad=owner_user_id||v||filename))",
  "image_nonce": "base64(24 bytes)",
  "ocr_ct":    "base64(XChaCha20Poly1305(K, ocr_nonce, ocr_text, aad=owner_user_id||v||filename))",
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

### 3.4 AEAD additional-data binding (prevents cross-user substitution)

Every ciphertext's AEAD additional-data field includes the `owner_user_id`
(plus format version and item id). The enclave, when decrypting an item it
just fetched from Flask under user A's authorization, asserts that the
authenticated `owner_user_id == A`. If the server (or a tampered server)
substitutes user B's ciphertext for user A's, the AEAD tag verification
fails and the enclave refuses to decrypt.

**Attack this defeats:** a malicious Feedling operator who controls the
Flask backend (or redirects `FEEDLING_FLASK_URL` to an attacker-controlled
instance) tries to feed user B's ciphertexts to user A's authorized
session. The enclave would otherwise happily decrypt them (the
`K_enclave` wrap is valid for the enclave's own keypair regardless of who
owns the content). The AEAD binding turns this into an integrity failure.

**Why the cheap option is enough:** we bind only what the server already
knows as plaintext metadata (user_id, item id, format version). We do not
need to encrypt these — we need to make them unforgeable inputs to the
ciphertext verification. The AEAD guarantee is exactly that.

---

## 4. Indexing and aggregation compute location

This is the single organizing principle for *"where does non-trivial compute
over user content run?"* It resolves not just today's classifier and
aggregation choices but every future server-side feature we'll want to add.

### 4.1 Principle

**v1 / default: all indexing, classification, search, and aggregation
compute runs on iOS.** Anything that needs to look across a user's frames,
memories, chat, or identity card happens on the device. The server sees
encrypted blobs plus the minimum plaintext metadata needed for routing
(timestamps, ids, roles). No exceptions by default.

**v2 / opt-in: user-placed cron jobs inside the enclave.** When a user
explicitly wants server-side compute — e.g. *"email me a weekly TikTok
report,"* *"run a better ML classifier on new frames,"* *"let me search
across all my memories server-side"* — they opt in to a named job spec.
That job runs inside the TDX enclave, with a short-lived decryption
capability that iOS delegates specifically for that job. Output is
delivered through a user-approved channel (email, push, a new MCP tool,
or a pull-based API).

### 4.2 Why this framing

1. **Privacy default is tight.** A new Feedling engineer who wants to add
   a server-side feature must first answer *"is this a v2 user-opt-in cron,
   or is this already supported in the v1 iOS path?"* There is no
   accidental path to server-side plaintext access.

2. **One uniform decision for every future feature.** ML-model-powered
   classifier, weekly summary email, cross-memory semantic search,
   research-consented aggregation, any SaaS integration that needs
   bulk-read access — they all get the same answer: *does the user
   explicitly opt in?* Scales better than case-by-case arbitration.

3. **The upgrade path is visible and user-owned.** A user can see, in
   Settings, the list of enclave-cron jobs they've approved. Each job
   has a name, what data it touches, what outputs it produces, and a
   revoke button. Permissions are concrete and auditable, not buried in
   a ToS.

4. **The enclave's TCB doesn't bloat for features nobody has asked for
   yet.** Bigger classifiers, server-side search indexes, analytics —
   none of them need to ship in Phase 1. They ship Phase 6+ as the
   specific opt-in features users are willing to trade some privacy for.

### 4.3 How v2 enclave-cron will work (sketch, for Phase 6)

When we eventually add a specific v2 feature (weekly summary email as
the most likely first one):

1. Feedling publishes a **job spec** in the enclave image: the exact
   Python code that will run, what fields it reads, what outputs it
   produces, and its cron schedule.
2. User taps *"Enable weekly TikTok report"* in iOS Settings. iOS shows
   the job's plain-English description + a link to the code. User
   confirms.
3. iOS delegates a **scoped, time-limited decryption capability** to the
   enclave: specifically, the user's `content_privkey` wrapped under the
   enclave's attested pubkey, with an attached constraint token
   authorizing only this named job, only for the expected data fields,
   expiring at the next natural refresh.
4. The enclave stores the delegation alongside the user's record. On
   schedule, it runs the job inside TDX, producing an output
   (e.g. an email body). Output leaves the enclave via the user-approved
   channel.
5. User can revoke at any time in Settings → Privacy → Enclave Jobs.
   Revocation means deleting the delegation blob on our side; a malicious
   server keeping a copy still can't use it once the enclave image
   rotates.

None of this ships in Phases 1–5. It's called out here so the early
architecture doesn't accidentally preclude it.

### 4.4 What this means concretely for decisions §12.4, §12.5, §12.6

- **Frame `app` field encrypted.** Per-app aggregation (weekly screen
  time, top-apps list, etc.) runs on iOS in v1. When users ask for
  "Feedling emails me weekly screen-time summaries," that's v2 cron.
- **Semantic classifier on iOS.** The 30-line keyword matcher today
  lives on the phone. When we want a real on-device model, we ship it
  in the iOS app. When we want a heavier server-side model, it's a v2
  cron feature users opt in to per-classifier.
- **Identity-dim values encrypted.** Cross-user aggregation
  ("population distribution of 温柔 scores for research purposes") is
  v2 opt-in with explicit research consent.

---

## 5. Attestation protocol

The primary attested identity for our deployment is **`compose_hash`** —
the SHA-256 of our `app-compose.json` manifest. It lives in the TDX quote's
RTMR3 register (per dstack's conventions; see
[dstack-tutorial/01-attestation-and-reference-values](https://github.com/amiller/dstack-tutorial/tree/main/01-attestation-and-reference-values)).
`MRTD` + `RTMR0-2` only identify the *base image* (dstack's generic TDX
runtime). Feedling's *specific deployment* is identified by RTMR3.

Authorization for a given `compose_hash` is enforced by an **AppAuth
contract on Base L2** (see
[dstack-tutorial/05-onchain-authorization](https://github.com/amiller/dstack-tutorial/tree/main/05-onchain-authorization)).
Dstack's KMS queries this contract before releasing derived keys to the
CVM: if the running `compose_hash` isn't on the on-chain whitelist, the
TEE never gets its keys and cannot serve traffic. Publishing a new version
is a single on-chain transaction; the event log on Basescan is the
permanent, public audit trail.

### 5.1 What the enclave publishes

On CVM boot, the enclave derives its keypair(s) via dstack's `getKey()`
(which internally checks `AppAuth.isAppAllowed(compose_hash)` and only
returns a key if authorized), generates its TLS cert, then requests a TDX
quote from dstack's guest agent. The quote's `REPORT_DATA` field (64 bytes)
is populated with:

```
REPORT_DATA = sha256( enclave_content_pk  ||
                      sha256(enclave_tls_cert_der)  ||
                      "feedling-v1" )
            || version_byte || flag_byte || reserved (14 bytes)
```

The `compose_hash` is *not* in REPORT_DATA — it's already present in RTMR3,
which is part of the TDX quote's measured values and cannot be forged.

The quote is served at `https://mcp.feedling.app/attestation` as:

```jsonc
{
  "tdx_quote_b64": "...",                      // raw TDX quote from Intel
  "enclave_content_pk_b64": "...",             // 32 bytes, X25519 pubkey
  "enclave_tls_cert_pem": "-----BEGIN CERT-----\n...",
  "enclave_signing_pk_b64": "...",             // 32 bytes, Ed25519 pubkey
  "enclave_release": {
    "git_commit": "abc123...",                 // commit hash of the enclave source
    "image_digest": "sha256:...",              // digest of the container image
    "built_at": "2026-05-01T00:00:00Z",
    "compose_yaml_url": "https://github.com/Account-Link/feedling-mcp-v1/raw/abc123.../deploy/docker-compose.yaml",
    "dockerfile_url":   "https://github.com/Account-Link/feedling-mcp-v1/raw/abc123.../deploy/Dockerfile",
    "build_recipe_url": "https://github.com/Account-Link/feedling-mcp-v1/blob/abc123.../deploy/BUILD.md"
  },
  "dstack_meta": {
    "base_image_measurement": "...",           // dstack OS MRTD + RTMR0-2 (published by Phala)
    "compose_hash_rtmr3": "...",               // the RTMR3 value; our canonical "which deployment is this"
    "app_auth_contract": "0xFeedlingAppAuth…", // Base L2 address, constant across deploys of this app
    "app_auth_chain_id": 8453
  }
}
```

This endpoint is unauthenticated and heavily cached (changes only at CVM
boot or cert rotation).

### 5.2 iOS auditor (the is-this-real-tea skill, on-device)

The iOS app ships as an active auditor, not a passive verifier. Every
session start (cached 24h) runs the full is-this-real-tea checklist against
the live deployment and surfaces a user-facing audit card (§5.3). The
audit has no single "accept-list on the phone" — the **phone reads the
on-chain AppAuth contract** and uses that as the source of truth for
what's authorized.

Pseudocode:

```swift
func auditFeedling() throws -> AuditReport {
    let bundle = try fetchAttestation("https://mcp.feedling.app/attestation")
    var report = AuditReport(timestamp: .now)

    // ─── 1. Is the hardware actually attesting? ────────────────────
    try IntelDCAP.verify(quote: bundle.tdx_quote_b64, rootCA: pinnedIntelRoot)
    report.add(.hardwareAttestationValid)

    // ─── 2. Is the base image the published dstack OS? ─────────────
    let baseMeasurement = IntelDCAP.extractMRTD_plus_RTMR0_2(bundle.tdx_quote_b64)
    guard baseMeasurement == bundle.dstack_meta.base_image_measurement,
          isEndorsedDstackImage(baseMeasurement)
    else { throw .unexpectedBaseImage(baseMeasurement) }
    report.add(.baseImageEndorsed(measurement: baseMeasurement))

    // ─── 3. What exact compose is running? ─────────────────────────
    let composeHash = IntelDCAP.extractRTMR3(bundle.tdx_quote_b64)
    guard composeHash == bundle.dstack_meta.compose_hash_rtmr3
    else { throw .composeHashMismatch }
    report.add(.composeHashFromQuote(composeHash))

    // ─── 4. Is this compose authorized on-chain? ───────────────────
    // Belt-and-suspenders: if the CVM is serving us at all, DstackKms
    // already checked this. We re-check via a public Base RPC so the
    // user sees the audit trail explicitly.
    let appAuth = BaseRPC.appAuthContract(bundle.dstack_meta.app_auth_contract)
    let authEvent = try appAuth.findComposeHashAddedEvent(composeHash)
        ?? { throw .composeHashNotOnChain(composeHash) }()
    report.add(.composeAuthorizedOnChain(
        contract: appAuth.address,
        txHash: authEvent.txHash,
        blockNumber: authEvent.blockNumber,
        basescanURL: "https://basescan.org/tx/\(authEvent.txHash)"
    ))

    // ─── 5. Can the operator redirect user data?  ───────────────────
    // Fetch the attested compose.yaml + Dockerfile from the URLs the
    // quote commits to, recompute compose_hash locally, confirm it
    // matches what the chain and the quote both reference.
    let composeYaml = try fetchAndHash(bundle.enclave_release.compose_yaml_url,
                                       expectedDigest: nil)
    let recomputed = composeHashOf(appComposeJson: buildAppComposeJson(composeYaml))
    guard recomputed == composeHash else { throw .composeDoesNotReproduce }
    report.add(.composeDoesReproduce)

    let audit = auditComposeForOperatorControl(composeYaml)
    // auditComposeForOperatorControl implements the is-this-real-tea checks:
    //   - no unpinned docker tags (all images by @sha256:…)
    //   - no bind-mounts to writable host paths
    //   - no security-relevant envs with ${…} defaults the operator can override
    //   - no outbound URLs that aren't baked in
    //   - no admin endpoints lacking auth
    try audit.assertPasses()
    report.add(.noOperatorControllableRedirects)
    report.add(.allImageDigestsPinned)

    // ─── 6. Is the TLS cert bound to this attestation? ─────────────
    let reportData = IntelDCAP.extractReportData(bundle.tdx_quote_b64)
    let expected = SHA256(
        bundle.enclave_content_pk +
        SHA256(bundle.enclave_tls_cert_der) +
        "feedling-v1"
    )
    guard reportData.prefix(32) == expected else { throw .reportDataMismatch }
    report.add(.tlsCertBoundToAttestation)

    // ─── 7. Can I rebuild the code? ────────────────────────────────
    // Not a runtime check — we verify that the build recipe URL exists
    // and is reachable. Deep reproducibility is the auditor's job.
    try HTTP.head(bundle.enclave_release.build_recipe_url)
    report.add(.buildRecipePublished(url: bundle.enclave_release.build_recipe_url))

    // ─── cache + return ────────────────────────────────────────────
    try trustStore.pin(
        composeHash: composeHash,
        enclaveContentPk: bundle.enclave_content_pk,
        tlsCertFingerprint: SHA256(bundle.enclave_tls_cert_der),
        expires: .now + 24.hours
    )
    return report
}
```

TLS connections to `mcp.feedling.app` use a custom `ServerTrust` evaluator:
the presented cert's SHA-256 fingerprint must match the one pinned in
step 6. Standard Let's Encrypt CA verification is still performed — TEE
attestation is additive, not a replacement for PKI.

### 5.3 Audit card UX

Every launch, Settings → Privacy renders the latest `AuditReport`:

```
┌──────────────────────────────────────────────────────────┐
│  🔒 Feedling audit — verified just now                   │
│                                                          │
│  ✅ Hardware attestation valid (Intel TDX)              │
│  ✅ Base image: dstack-v0.5.3 (Phala endorsed)          │
│  ✅ Running compose: c1a3b7… (entry #7 on Basescan)     │
│  ✅ compose_hash authorized on-chain                     │
│     AppAuth contract: 0xFeedling…Auth                   │
│     tx: 0xabc… · block 12345678 · 2026-05-01            │
│     [ View on Basescan ]                                │
│  ✅ Published compose matches attested compose_hash      │
│  ✅ No operator-controllable URLs in compose             │
│  ✅ All image digests pinned (no mutable tags)          │
│  ✅ TLS cert bound to hardware attestation               │
│  ✅ Reproducible build recipe published                  │
│                                                          │
│  Report generated on-device from on-chain data.         │
│  [ Share report ]   [ View enclave source ]             │
└──────────────────────────────────────────────────────────┘
```

If any check fails, the app refuses to use the endpoint and surfaces the
specific failure with a link to the relevant reference doc in
[`is-this-real-tea`](https://github.com/sxysun/is-this-real-tea). The
phone acts as the user's personal auditor.

For routine releases we publish the new `compose_hash` on-chain *before*
the CVM starts serving it. Users with an old cached version see a
"Feedling deployed a new version on Basescan" notice next session,
auto-fetch, auto-verify, auto-approve if everything passes — no manual
review unless something about the deployment is surprising.

---

## 6. Core data flows

### 6.1 Registration

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

### 6.2 Content write (chat message example)

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

### 6.3 Content read by Agent via MCP

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

### 6.4 Rotation

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

### 6.5 Migration from today's plaintext data

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

## 7. Component architecture

```
                    ┌────────────────────────────────────────┐
                    │ Base L2 (public chain)                 │
                    │                                        │
                    │   AppAuth contract                     │
                    │     owner = Feedling release key       │
                    │     whitelist of compose_hashes        │
                    │     event log = permanent audit trail  │
                    │                                        │
                    │   Queried by DstackKms at key-release  │
                    │   Queried by iOS for audit             │
                    └──▲─────────────────────────────────▲──┘
                       │                                 │
                       │ tx (rare, one per deploy)       │ RPC read
                       │                                 │ (free, any public node)
┌──────────────────────┴───────────────────────────────────────────┐
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
│   No security-relevant env vars are operator-settable — see §7.2 │
└──────────────────────────────────────────────────────────────────┘
                        │                          │
                        │ (internal HTTPS)         │ (TCP)
                        ▼                          │
┌──────────────────────────────────────────────────▼───────────────┐
│ dstack CVM on Phala (Intel TDX)                                  │
│                                                                  │
│   rustls TLS :5002                                               │
│     cert: Let's Encrypt (ACME-DNS-01 from inside CVM)            │
│     privkey: sealed in CVM, never persisted outside TEE          │
│                                                                  │
│   FastMCP SSE server :5002                                       │
│     14 tools; handlers decrypt ciphertexts before returning      │
│                                                                  │
│   Decryption oracle                                              │
│     enclave_content_sk via dstack.getKey(),                      │
│     which requires AppAuth.isAppAllowed(compose_hash) == true    │
│                                                                  │
│   Attestation server (read-only)                                 │
│     GET /attestation → tdx_quote + pubkeys + release info        │
│                                                                  │
│   HTTP client to Flask (internal, ciphertext in / plaintext only │
│     materializes inside enclave)                                 │
└──────────────────────────────────────────────────────────────────┘
                        ▲
                        │ attestation fetch
                        │ on-chain read of AppAuth events
                        │
                   ┌────┴────┐
                   │ iOS app │   runs the full audit on every session
                   └─────────┘
```

### 7.1 Why split this way

- **Flask outside TEE:** never touches plaintext; putting it in the TEE
  adds TCB without adding security. Disk I/O and WebSocket ingest are
  operationally simpler outside a CVM. Crashing Flask doesn't crash the
  TEE.
- **Caddy outside TEE:** thousands of lines, well-audited, doesn't see
  plaintext (SNI pass-through for `mcp.feedling.app`, and `api.feedling.app`
  only ever sees ciphertext bodies).
- **AppAuth on Base (not our server):** a signed log on a Feedling server
  would be useless — we could rewrite it. Base L2 consensus is the
  enforcement and audit boundary.
- **iOS as the auditor:** the phone reads both the enclave attestation
  and the on-chain history, and does the full is-this-real-tea checklist
  itself.

### 7.2 Env-var hygiene (operator cannot rug via config)

Any env var that affects a security-relevant behavior *must* be either
baked into the compose (and therefore covered by `compose_hash`) or
derived from a dstack-attested primitive at runtime. The compose file we
ship to Phala is reviewed against this rule at every release.

Specifically, in `deploy/docker-compose.yaml` the following have to be
pinned (not `${…}`-overridable by whoever deploys the CVM):

| Variable | Why it's dangerous if operator-mutable |
|---|---|
| `FEEDLING_FLASK_URL` | Redirecting to attacker-controlled Flask lets them feed the enclave another user's ciphertext for decryption to a session they authorize. Defeated by AEAD+user_id binding (§3.4) even so, but pinning is defense-in-depth. |
| `SINGLE_USER` | Operator could disable auth by flipping this. |
| `FEEDLING_MCP_TRANSPORT` | Changing transport could silently downgrade security properties. |
| Any `_URL` variable | Could redirect outbound data to attacker infra. |
| Any `_KEY` or `_SECRET` | Shared secrets baked into the measured compose, not injected at deploy time. |

The only env vars allowed to stay operator-settable are things that
genuinely don't affect trust (e.g. verbosity, cache sizes, non-security
timeouts). Each one is explicitly justified in a comment in the compose.

**Audited by the phone.** The iOS audit (step 5 in §5.2's pseudocode)
fetches the attested compose yaml and asserts every security-relevant
env is literally pinned, not `${VAR_NAME}`-templated. If the rule is
violated, the audit fails and the phone refuses the endpoint.

### 7.3 AppAuth contract (single-EOA owner, no timelock)

```solidity
// Deployed once on Base L2. Address is referenced by DstackKms configuration
// for our app and by the iOS auditor.
contract FeedlingAppAuth {
    address public owner;   // Feedling release EOA
    mapping(bytes32 => ReleaseEntry) public releases;

    struct ReleaseEntry {
        bool approved;
        uint64 approvedAt;
        string gitCommit;
        string composeYamlURI;  // GitHub raw URL pinned to the git_commit
    }

    event ComposeHashAdded(bytes32 indexed composeHash, string gitCommit, string composeYamlURI);
    event ComposeHashRevoked(bytes32 indexed composeHash);

    function addComposeHash(bytes32 h, string calldata gitCommit, string calldata composeYamlURI)
        external onlyOwner
    {
        releases[h] = ReleaseEntry(true, uint64(block.timestamp), gitCommit, composeYamlURI);
        emit ComposeHashAdded(h, gitCommit, composeYamlURI);
    }

    function revoke(bytes32 h) external onlyOwner {
        releases[h].approved = false;
        emit ComposeHashRevoked(h);
    }

    // Called by DstackKms before releasing keys to a CVM.
    function isAppAllowed(bytes32 composeHash) external view returns (bool) {
        return releases[composeHash].approved;
    }
}
```

Per dstack-tutorial/05, no timelock in v1. Adding one later is a one-line
change (add `uint64 activatesAt` and enforce `block.timestamp >= activatesAt`
in `isAppAllowed`). We leave the door open without shipping the governance
now. Similarly, moving `owner` from an EOA to a multisig contract is a
drop-in change when we outgrow single-key authority.

Cost per release: one `addComposeHash` transaction, ~$0.05 on Base L2.

---

---

## 8. iOS responsibilities (summary)

1. **Keypair lifecycle.** Generate, store in Keychain with
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Optionally export as
   encrypted mnemonic for backup (Phase 3).
2. **On-device auditor (the is-this-real-tea skill, in-app).** Ship with
   pinned Intel DCAP root CA, pinned AppAuth contract address, endorsed
   dstack base image measurements. On every session run the full §5.2
   audit and render the audit card.
3. **On-chain reader.** Query the AppAuth contract's event log via a
   public Base RPC (fall back across multiple providers). Display the
   full release history in Settings → Privacy → Release Log.
4. **Content encryption before any upload.** Every field that leaves the
   phone destined for storage goes through the sealed-box-to-both path
   with AEAD additional-data bound to `owner_user_id` (§3.4).
5. **Migration executor.** When `compose_hash` changes (enclave
   redeploy), unseal `K_user` locally and re-seal `K` to the new
   `enclave_content_pk`. Enclave reads see placeholders for
   not-yet-rewrapped items; iOS reads work as normal.
6. **Local decrypt path.** Chat / Identity / Memory Garden views decrypt
   directly on-device; they do not round-trip through the enclave.
7. **Local-only flag UI.** A "private memory" toggle on memory-add and a
   global default in Settings.

### 8.1 iOS dependencies (new)

- `swift-sodium` (libsodium bindings) — content encryption + AEAD.
- `SwiftDCAP` or a custom Swift wrapper around Intel's DCAP verify library —
  attestation verification. (Need to evaluate available libraries; may need
  to port a small one.)
- Ethereum light-client or plain-JSON-RPC client for reading AppAuth events
  on Base. Options: `web3.swift`, `Web3Core`, or a thin `URLSession`
  wrapper calling `eth_getLogs` on a pinned set of public RPC endpoints.
  No wallet / signing needed — read-only.

---

## 9. Phased implementation plan

Each phase is independently ship-able and does not break users on the
previous phase. Phases 1–5 constitute the MVP scope; Phase 6 is explicitly
future work enabling the v2 "enclave cron" path from §4.

### Phase 1 — TEE infrastructure + AppAuth on Base (~2 weeks)

- [ ] Provision a Phala dstack deployment per §12.1. Phala's managed TDX
      network for v1; self-hosted TDX later as a cost optimization.
- [ ] Reproducible container build for the enclave app. Pin base image
      `python:3.12-slim` by digest (`@sha256:…`). Lock pip deps with
      `--require-hashes`. Publish recipe + expected image digest at
      `deploy/BUILD.md`.
- [ ] Deploy `FeedlingAppAuth` contract on Base **sepolia** first (free),
      promote to Base mainnet before Phase 5. Configure dstack KMS to
      delegate authorization to it for our app ID. Call
      `addComposeHash()` for the first release compose.
- [ ] Minimal enclave service: `GET /attestation` returning the TDX quote
      (with correct `REPORT_DATA` binding), published pubkeys, and
      dstack-KMS-derived key material.
- [ ] iOS: add `swift-sodium`, add DCAP-verifying attestation library,
      add thin Base RPC client, ship with pinned Intel root + pinned
      AppAuth contract address + endorsed dstack base image measurement.
- [ ] E2E smoke test: iOS fetches attestation, verifies the full audit
      checklist (compose_hash matches RTMR3, is in AppAuth event log,
      compose reproduces, TLS cert bound), renders the audit card.

**Exit criterion:** iOS cryptographically verifies that the Phala enclave
is running a specific `compose_hash` that has been authorized on-chain via
AppAuth, and that the code corresponding to that hash is reproducibly
buildable from the pinned git commit. No content encryption yet.

### Phase 2 — Content encryption (iOS side) + dual-format backend + env-var hygiene (~2 weeks)

- [ ] Implement the content format (§3.2) on iOS: every chat / memory /
      identity / frame / OCR write goes through the double-wrap scheme
      with AEAD additional-data = `owner_user_id || v || id`.
- [ ] Flask: accept both plaintext (v0, legacy) and ciphertext (v1) forms on
      writes during the migration window. Store whichever arrived.
- [ ] Enclave: `/v2/*` tool handlers that unseal `K_enclave`, decrypt with
      AEAD-aad set to the authorized user_id, and refuse if aad ≠ that
      user_id. v0 requests continue to flow through Flask-direct.
- [ ] Audit `deploy/docker-compose.yaml` against §7.2 env-var hygiene rules.
      Bake every security-relevant value into the compose (no `${…}`
      overrides). Re-run `compose_hash` → publish on-chain as the v1
      release.
- [ ] Move the `_semantic_analysis()` classifier to iOS per decision §12.5.
      iOS uploads the tag (`semantic_scene`, `task_intent`) as plaintext
      metadata; raw OCR never leaves the phone unencrypted.
- [ ] iOS Migration UI: one-time "Encrypt your existing data" flow for
      pre-E2E users.

**Exit criterion:** A fresh iOS install writes ciphertext end-to-end; the
Agent reads via enclave decrypt with AEAD-bound user_id; existing users can
voluntarily upgrade. Compose has no operator-settable security knobs.

### Phase 3 — MCP moves into TEE + TLS termination + key backup (~1–2 weeks)

- [ ] Move FastMCP into the Phala CVM. Terminate TLS for `mcp.feedling.app`
      inside the CVM using rustls.
- [ ] Caddy config: `mcp.feedling.app` downgrades from `reverse_proxy` to
      `layer4 tls passthrough` — Caddy only routes by SNI, never
      decrypts.
- [ ] ACME-DNS-01 plumbing so the CVM can auto-renew certs without the
      TLS privkey ever existing outside TDX memory.
- [ ] iCloud Keychain backup of content `privkey` per decision §12.7: 24-word
      mnemonic shown once at onboarding, primary restore path is iCloud
      Keychain auto-sync across the user's Apple devices.
- [ ] Audit pass: confirm no plaintext can leave the CVM except as
      already-encrypted TLS bytes.

**Exit criterion:** A Feedling operator with full root on the non-TEE host
cannot observe active-session plaintext. Losing an iPhone no longer means
losing local data access.

### Phase 4 — Privacy UI + polish (~1 week)

- [ ] Settings → Privacy screen:
      - **Audit card** (§5.3 UX mock): one-glance ✅/❌ for each
        is-this-real-tea check, verified-at timestamp, Share button
      - Current `compose_hash`, git commit link, Basescan tx link for
        when this hash was added to AppAuth
      - Release history: scrollable list of `ComposeHashAdded` events
        from the on-chain log
      - Per-item `visibility` toggle on memory compose + chat compose
      - Global default visibility switch in Advanced (default `shared` per
        decision §12.3)
      - Placeholder row for future "Enclave jobs" (Phase 6) — ships empty
- [ ] MRTD-changed review card (per §5.3 UX mock).
- [ ] Migration status view.
- [ ] Onboarding copy with the three honest asterisks (§2.3 and §13) in
      plain language.

**Exit criterion:** A user can open the app cold and understand exactly who
can read their data, under what conditions, and what recourse they have.

### Phase 5 — Production cutover (~2–4 weeks rolling)

- [ ] Migrate prod users in batches. Email + in-app prompt.
- [ ] Retire v0 plaintext write endpoints over 30 days.
- [ ] Update website / product copy / `README.md` / `skill/SKILL.md` to
      reflect the new guarantees.
- [ ] Decommission old Flask-direct read paths for content (metadata/admin
      paths stay).

**Exit criterion:** 100% of active users on v1. Plaintext content endpoints
deleted from the codebase.

### Phase 6 — Future: user-placed enclave cron (post-MVP, not scoped)

This phase ships feature-by-feature as demand materializes. Each feature
introduces a new named job spec. Representative examples:

- [ ] Weekly screen-time summary email (job: aggregate frame metadata →
      format email → send via SendGrid).
- [ ] Heavier on-enclave semantic classifier with an embedded ML model.
- [ ] Cross-memory server-side search for users with large gardens.
- [ ] Opt-in research aggregation (e.g., "contribute anonymized 温柔-dim
      distribution to a public dataset").

Each shipped job spec follows the delegation pattern in §4.3: scoped,
time-limited, user-revocable. None of them changes the Phase 1–5
architecture.

Total calendar time to Phase 5 cutover: **~6–7 weeks** of engineering.

---

## 10. Threat model

### 10.1 Adversaries we defend against

| Adversary | Attack | Defense |
|---|---|---|
| Network passive | Sniff traffic | TLS everywhere, TEE-terminated for MCP path |
| Network MITM | Hijack DNS, inject CA | TLS pinning of enclave cert via attestation |
| Feedling disk breach | Dump `feedling-data/` | Data at rest is ciphertext; key material only inside TEE or on user phones |
| Feedling operator (passive) | Read files, attach gdb to processes | Non-TEE process never has plaintext; TEE inaccessible from host |
| Feedling operator — redirect FLASK_URL | Point enclave at attacker-controlled Flask, feed user-B's ciphertext to user-A's session | AEAD additional-data binds ciphertext to `owner_user_id` (§3.4); enclave refuses cross-user ciphertexts. Defense-in-depth: env-var hygiene (§7.2) pins FLASK_URL into the compose so it can't be changed without changing compose_hash, which triggers AppAuth gate. |
| Feedling rogue dev — push malicious code | Deploy backdoored enclave that logs plaintext | DstackKms gates on `AppAuth.isAppAllowed(compose_hash)`. Without an on-chain tx adding the new hash, the TEE gets no keys and cannot serve. Silent updates are impossible — they require a publicly visible Base transaction. iOS audit card also flags the new hash for the user. |
| Feedling rogue dev — inject env var | Change runtime behavior without changing code | Env-var hygiene (§7.2): security-relevant envs are baked into compose → covered by compose_hash → AppAuth gated. |
| Feedling VPS root compromise | Full host access | TEE isolation holds. AEAD+user_id binding prevents cross-user ciphertext substitution. |
| Physical theft of VPS disk | Cold boot of drive | Ciphertext only |
| Compromised Agent | Agent-side exfil | Out of scope — any data the Agent is authorized to read can be exfiltrated by a compromised Agent. Limit blast radius with per-item local-only. |
| Lost / stolen iOS device | Attacker has phone | Keychain requires device passcode / biometrics post-first-unlock; api_key remotely revocable via a different device |
| Compromised Feedling release key | Operator signs a malicious `addComposeHash()` tx | The malicious hash is still visible on Basescan. Revocation: call `revoke()` from the owner key (if not compromised) or rotate owner via a fresh deploy + user-notified migration. iOS surfaces a revoked status in the audit card. |

### 10.2 Adversaries we do NOT defend against

| Adversary | Why | Mitigation |
|---|---|---|
| Intel TDX hardware break | We run on top of TDX | Fall back to "ciphertext at rest + TLS in flight" — still better than most SaaS |
| Malicious iOS update that we ship | We sign iOS builds | Published IPA hashes, third-party audit, self-host escape hatch |
| Malicious Agent (Anthropic, OpenAI etc.) | Agent receives plaintext to function | Use local Agent for agent-side privacy |
| User's compromised phone | Malware with Keychain access | Standard iOS threat model; users should lock device, update iOS |
| State-level actor targeting specific users | TDX side-channels, social eng., legal process | Beyond product scope |

---

## 11. Operational concerns

### 11.1 Debugging

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

### 11.2 Disaster recovery

- **Flask data:** ciphertext backups are fine to store in S3 / wherever;
  nobody can read them without a user's iOS device.
- **Enclave keys:** deterministic from dstack KMS + MRTD. To restore, redeploy
  the same image. Data re-encrypted under the same MRTD is still readable.
- **User iOS device loss:** if we implement Phase-2 Keychain export, user
  restores from iCloud. Otherwise, their local read access is lost, but the
  enclave path (remote Agent reads) keeps working indefinitely via the
  stored api_key.

### 11.3 Cost

- Phala-deployed TDX CVM: see Phala's pricing for current rates. Ballpark
  ~$40–$150/month for a small instance sufficient for a low-to-medium
  traffic MCP server. Migrating to self-hosted TDX later is a cost
  optimization, not an architectural change.
- Additional TCP bandwidth for TLS pass-through: negligible.
- Engineering time: ~6 weeks as laid out.

---

## 12. Decisions (locked)

Decisions 12.1-12.8 locked in v0.2. Decisions 12.9-12.12 added in v0.3
after working through the threat model implied by
[`sxysun/is-this-real-tea`](https://github.com/sxysun/is-this-real-tea)
and [`amiller/dstack-tutorial`](https://github.com/amiller/dstack-tutorial).
Each answer is load-bearing — later phases assume these.

### 12.1 TDX deployment target: **Phala**

Chosen over GCP Confidential VM / Azure Confidential Computing / self-hosted
bare metal.

**Rationale:** Phala's managed TDX network gives us public,
third-party-verifiable attestation out of the box — any user (or auditor) can
independently check that the measurement we publish matches what's actually
running. The "anyone can verify" property matches the product's privacy
narrative better than a single-cloud provider. Operational cost is slightly
higher than GCP for equivalent CPU, but the auditability is worth it and we
can migrate off Phala later without changing the cryptographic construction.

**Implication:** Phase 1 integrates with dstack (Phala's TDX runtime). The
enclave container must be publishable to Phala's infrastructure. Our
`deploy/docker-compose.yaml` stays the unit of deployment.

### 12.2 MRTD pre-approval cadence: **monthly batches + review-card for emergency patches**

Pre-ship upcoming MRTDs in the iOS binary on a monthly release cadence so
99% of enclave updates are silent for users. Emergency patches between iOS
releases trigger the review card UX from §5.3.

**Rationale:** Silent updates undermine the "your phone verifies our code"
story. Surfaced updates with a diff link let users participate in the change
consciously — which is the whole point of attestation. Monthly batching keeps
the prompt rare enough not to train users to tap "Approve" reflexively.

**Implication:** Our deploy process always ships iOS release alongside
enclave release. Out-of-band enclave hotfixes are rare and visible.

### 12.3 Default visibility: **`shared`**

New content items default to `visibility: "shared"` (both user and enclave
can decrypt). A per-item toggle exposes `local_only`; a global default
switch in Advanced Settings lets power users flip the baseline.

**Rationale:** Defaulting to `local_only` makes the Agent experience feel
broken ("Claude doesn't remember our previous conversation"). Default-shared
keeps the product coherent while still letting any user with a concrete
privacy need scope individual items or flip the default.

**Implication:** iOS UI ships with a small "🔒 private" toggle on memory-add
and chat-compose. Advanced Settings exposes the global default.

### 12.4 Frame `app` field: **encrypted**

Foreground-app bundle IDs are wrapped alongside image and OCR, not kept
plaintext for server-side aggregation.

**Rationale:** *"You were in Signal at 11pm"* is exactly the kind of
metadata we claimed not to leak. Per-app aggregation (weekly screen time,
top-apps list, etc.) moves to iOS (§4 principle). Any future "Feedling
emails me a weekly summary" feature becomes a v2 enclave-cron opt-in.

**Implication:** `/v1/screen/analyze` returns tags derived on iOS;
server-side per-app dashboards are off the roadmap for v1.

### 12.5 `_semantic_analysis()` classifier: **on iOS**

The current 30-line keyword matcher moves to the iOS client. iOS uploads
the resulting tag (`semantic_scene`, `task_intent`, `friction_point`) as
plaintext metadata — the raw OCR never leaves the phone in plaintext.

**Rationale:** Keeps the enclave TCB small. The classifier is tiny and
doesn't need server-side state. When we later want a heavier on-device ML
model, it's an iOS release. When we want a heavy server-side model, it's
a v2 enclave-cron feature per §4.

**Implication:** iOS picks up a small classifier library (the same Python
logic ported to Swift). Server still consumes the tag for cooldown / trigger
decisions.

### 12.6 Identity-dim values: **encrypted**

0–100 integer values in the identity card are wrapped under the double-wrap
scheme like all other content.

**Rationale:** Consistency. The storage cost is trivial. Cross-user
aggregation ("distribution of 温柔 scores across users") becomes a v2
opt-in enclave-cron feature with explicit research consent.

**Implication:** Server sees encrypted integer fields; iOS and Agent
(via enclave decrypt) see plaintext.

### 12.7 Content key backup: **Phase 3, iCloud Keychain as primary**

Backup ships in Phase 3 (alongside MCP-in-TEE), not deferred to Phase 5.
Primary mechanism: the content private key is stored under iOS Keychain
with `kSecAttrSynchronizable = true`, allowing iCloud Keychain to sync
across the user's Apple devices. Secondary fallback: a one-time 24-word
BIP39-style mnemonic shown during onboarding for users who distrust iCloud
or want paper backup.

**Rationale:** Losing a phone before backup = losing local read access.
Remote reads via the enclave still work (api_key resurrects with a new
phone) but offline mode and local decrypt break. Phase 3 timing means
backup is live before we ask any user to migrate their production data in
Phase 5.

**Implication:** Phase 3 scope grows slightly. Phase 4 Privacy UI exposes
"Your encryption key is backed up to iCloud Keychain" status plus "show
mnemonic" action.

### 12.8 Indexing/aggregation compute location: **v1 iOS, v2 enclave-cron opt-in**

See §4 for the full principle. Not a separate question but stated here for
completeness since several of the above decisions depend on it.

### 12.9 Attested identity: **`compose_hash` in RTMR3**, not MRTD

MRTD + RTMR0-2 identify only the dstack base image, which is the same for
every dstack-deployed app. Our specific deployment is identified by the
`compose_hash` in RTMR3 per dstack-tutorial/01. iOS verifier treats MRTD
as a secondary "endorsed base image" check and RTMR3 as the primary
"which Feedling deployment is this."

### 12.10 Transparency mechanism: **on-chain AppAuth on Base L2**

Per dstack-tutorial/05. Single-EOA owner, no timelock, no multisig for v1
(explicitly the user's request). The contract is queried by DstackKms
before any key release — so "silently deploy bad code" is architecturally
impossible, not just detectable. Basescan is the permanent audit trail.
A Sigstore Rekor mirror can be added later as belt-and-suspenders but is
not required.

**Why this over a signed log on feedling.app:** a log we control can be
rewritten unilaterally. Base L2's append-only property is a consensus
guarantee we cannot bypass even if we wanted to. See §10 threat model
"rogue dev" row.

### 12.11 Env-var hygiene and image pinning: **no operator-settable security knobs**

Every security-relevant env in `deploy/docker-compose.yaml` is baked into
the compose (covered by `compose_hash`) or derived from an attested
dstack primitive at runtime. All docker images are pinned by `@sha256:…`,
never by tag. The iOS audit (§5.2 step 5) enforces this statically —
failure fails the audit and the phone refuses the endpoint.

### 12.12 AEAD binding: **`owner_user_id || v || item_id`** as AEAD additional-data

Prevents cross-user ciphertext substitution by a malicious server (§3.4).
No effect on storage layout, cryptographic cost is zero, security gain is
closing a real operator rug vector.

---

## 13. What we will tell users

Proposed marketing / onboarding copy:

> **Feedling's privacy guarantee, exactly.**
>
> Your chats, memories, identity card, and screen captures are encrypted on
> your iPhone before they ever leave your device. Feedling's servers hold
> your data as ciphertext blobs that our employees, our servers, and anyone
> who breaches us cannot read.
>
> When your Agent (Claude, ChatGPT, etc.) needs to read your data, it
> happens inside a hardware-isolated secure enclave whose exact code is
> published on GitHub. **Your iPhone is the auditor.** Every session it
> independently verifies that Feedling's enclave is running the exact code
> we published, that the code was authorized on a public blockchain, and
> that none of the security-sensitive settings can be changed by us
> without you seeing it.
>
> We cannot silently deploy code. Every version change is a permanent,
> timestamped entry on Base — anyone can see our full deployment history.
> If we try to ship a version your phone doesn't recognize, the app
> refuses and tells you why.
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
>    entire stack. Our `SKILL.md` has a runbook any agent can follow to
>    deploy Feedling to your own VPS.
>
> Everything else — our VPS, our database, our logs, our employees with
> SSH access, any future version of ourselves that turns evil — cannot
> read your data. That's the whole design.

---

## 14. How to audit us

Feedling is auditable from the outside by anyone, using the exact tools
this project's own audit skill was built around:
[`sxysun/is-this-real-tea`](https://github.com/sxysun/is-this-real-tea).

### 14.1 What to check

Point `is-this-real-tea` at our repo + deployed endpoint:

```
Read https://raw.githubusercontent.com/sxysun/is-this-real-tea/main/AGENT.md
and then audit this TEE app:
  repo: https://github.com/Account-Link/feedling-mcp-v1
  url:  https://mcp.feedling.app
```

The audit tool will check, and we commit to passing all of these:

| Check | What we do |
|---|---|
| All external URLs handling user data are hardcoded | Verified by §7.2 env-var hygiene rule |
| Docker images pinned by `@sha256:…` | Enforced in `deploy/Dockerfile` + `deploy/docker-compose.yaml` |
| Reproducible builds from the published git commit | Recipe at `deploy/BUILD.md`, CI verifies digest |
| Code changes publicly logged with audit trail | `FeedlingAppAuth` events on Base L2 |
| TLS cert cryptographically bound to attestation | §5.1 `REPORT_DATA` construction |
| Attestation actually used for key derivation | `dstack.getKey()` + `AppAuth.isAppAllowed()` gating |
| No admin endpoints without auth | Audited at every release; only `/healthz` is public |
| No fallback to non-attested decrypt | Enclave has no path to return plaintext without dstack KMS approval |

### 14.2 Artifacts we publish

- **Source:** https://github.com/Account-Link/feedling-mcp-v1
- **Build recipe + expected image digest:** `deploy/BUILD.md` on every
  tagged release.
- **Release-signing pubkey fingerprint:** pinned in iOS binary, also
  published to our release notes. Rotations are themselves announced via
  a `ComposeHashAdded` event that references the new key.
- **AppAuth contract address on Base:** published in iOS binary + in this
  doc + in the enclave's `/attestation` response.
- **Latest compose_hash + its Basescan link:** shown in every user's
  Settings → Privacy. Also queryable from `/attestation`.
- **Enclave's live attestation quote:** `https://mcp.feedling.app/attestation`
  returns the current TDX quote plus `compose_hash_rtmr3`, signed by
  Intel's attestation infrastructure, fresh on every CVM boot.

### 14.3 References for auditors

- Audit tool: https://github.com/sxysun/is-this-real-tea
- Pattern we follow: [`dstack-tutorial/05-onchain-authorization`](https://github.com/amiller/dstack-tutorial/tree/main/05-onchain-authorization)
- Reference values explanation: [`dstack-tutorial/01-attestation-and-reference-values`](https://github.com/amiller/dstack-tutorial/tree/main/01-attestation-and-reference-values)

### 14.4 Scope of our claim

We claim:

- Feedling's servers cannot read your content at rest or in flight
  (§2, §3, §5).
- Silent code updates are impossible — every change is visible on
  Basescan and the running code is gated by on-chain authorization
  (§5, §7.3, §12.10).
- Operators cannot rug via env vars or config tweaks (§7.2, §10).
- Cross-user ciphertext substitution is cryptographically detected
  (§3.4, §12.12).
- The iOS app actively verifies the above on every session and surfaces
  a failure if any check breaks (§5.2, §5.3).

We do NOT claim:

- That Anthropic / OpenAI / your Agent can't read the data your Agent is
  authorized to read.
- That Intel TDX is unbreakable — if it is, we degrade to "ciphertext at
  rest + TLS in flight," which is still better than ~every SaaS today.
- That our iOS binary is perfectly attested against Apple's
  infrastructure — published hashes + audits are currently the best we
  have.

These boundaries are in §10 threat model. Anything outside them, we will
not promise.

---

## 15. References

- `docs/NEXT.md` — prerequisite multi-tenant backend this layers on top of.
- `skill/SKILL.md` — self-hosted runbook for users who prefer that over TEE.
- `deploy/BUILD.md` (to be written in Phase 1) — reproducible build recipe
  for the enclave container image.
- **Audit tool: <https://github.com/sxysun/is-this-real-tea>** — the
  threat-model framework this doc is designed to pass.
- **dstack framework:** <https://github.com/Dstack-TEE/dstack>
- **dstack tutorial (@amiller):** <https://github.com/amiller/dstack-tutorial>
  - §01 attestation-and-reference-values — framing RTMR3 / compose_hash
  - §02 bitrot-and-reproducibility — reproducible builds
  - §05 onchain-authorization — AppAuth + DstackKms delegation (our §7.3)
  - §08 extending-appauth — timelocks + multi-vendor (future upgrade path)
- Intel TDX attestation spec: <https://cdrdv2-public.intel.com/726790>
- libsodium sealed boxes: <https://doc.libsodium.org/public-key_cryptography/sealed_boxes>
- libsodium AEAD (XChaCha20-Poly1305): <https://doc.libsodium.org/secret-key_cryptography/aead>
- Apple CryptoKit Curve25519: <https://developer.apple.com/documentation/cryptokit/curve25519>

---

## 16. Change log

- v0.3 (2026-04-19): Stage 1 DevProof alignment. Adopted the
  dstack-tutorial/05 `AppAuth` pattern on Base L2 as the authorization +
  transparency mechanism (enforcement at key-release time, not just
  audit). Replaced "signed transparency log on feedling.app" from the
  v0.2 plan because a log we host is unilaterally rewritable.
  Corrected the attested identity from `MRTD` alone to `compose_hash` in
  RTMR3 per dstack-tutorial/01. Added AEAD additional-data binding to
  `owner_user_id` (§3.4) to defeat cross-user ciphertext substitution.
  Added §7.2 env-var hygiene rules and §7.3 AppAuth contract sketch.
  Rewrote §5 iOS verifier to be an active is-this-real-tea-style
  on-device auditor. Added §10 threat-model rows for operator rug
  vectors (FLASK_URL redirect, malicious env var, rogue deploy) and
  their specific defenses. Added §12.9-§12.12 decisions. Added §14
  "How to audit us" as a new section cross-linking to
  `sxysun/is-this-real-tea`. Bumped §15 References, §16 Change log.
- v0.2 (2026-04-19): decisions locked. Added §4 indexing-location principle
  (v1 iOS, v2 enclave-cron opt-in) and cross-referenced into §12.
  Resolved all seven v0.1 open questions; §11 renamed to §12 *"Decisions
  (locked in v0.2)"* with rationale per item. TDX target chosen: **Phala**.
  Restructured §9 (was §8) phases to a crisper 6-phase layout; Phase 6
  added as explicitly future / post-MVP for the enclave-cron features.
  Section numbering shifted by +1 from §4 onward to accommodate the new
  §4.
- v0.1 (2026-04-19): initial draft. Owner: @sxysun. Pending review +
  decisions on seven open questions before Phase 1 starts.
