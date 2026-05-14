# FeedlingDCAP

Swift package: the iOS side of Feedling's on-device attestation auditor.
Parses and verifies Intel TDX v4 quotes so the iOS app can confirm what
the enclave measured before trusting it with user keys.

See `docs/DESIGN_E2E.md` §5.2 for the role this plays in the overall
architecture.

## Prior art / reference implementations

- **[dcap-qvl](https://github.com/Phala-Network/dcap-qvl)** — Phala's
  production Rust DCAP quote verifier. Used by dstack's own audit
  tooling (`dstack_audit/phases/attestation.py` shells out to `dcap-qvl
  verify --hex`). When we want to raise the confidence of this Swift
  port, a sensible path is to diff our output against dcap-qvl on the
  same input quotes and fix any drift. Can also be wrapped via FFI if
  we ever want to use it directly on iOS.
- **[SGXDataCenterAttestationPrimitives](https://github.com/intel/SGXDataCenterAttestationPrimitives)** —
  Intel's C/C++ reference. The authoritative spec.
- **[dstack-tutorial/dstack_audit](https://github.com/amiller/dstack-tutorial)** —
  The full audit pipeline that `sxysun/is-this-real-tea` is built on.
  Our `EventLogReplay` module (`testapp/FeedlingTest/EventLogReplay.swift`)
  re-implements the compose_hash-binding checks from that tutorial in
  Swift for on-device auditing.

## Status

This package is the Swift mirror of the Python DCAP parser/verifier used
by `tools/audit_live_cvm.py`. It is covered by `swift test` and the main
iOS app carries the production audit implementation under
`testapp/FeedlingTest/DCAP/`.

## Test

```bash
cd ios/FeedlingDCAP
swift test --parallel
```

Tests mirror the Python reference in `tools/dcap/` 1:1 — if one passes
and the other doesn't, the two implementations have drifted. Fixture
files (`sample_quote.hex`, `sample_attestation.json`) are shared source
of truth; regenerate by running `backend/enclave_app.py` against the
simulator and capturing `/attestation`.

## Layout

```
ios/FeedlingDCAP/
  Package.swift
  README.md
  Sources/FeedlingDCAP/
    Parser.swift          structural parse — done
    Verifier.swift        signature-chain verify — Phase 1E
  Tests/FeedlingDCAPTests/
    ParserTests.swift
    TestData/
      sample_quote.hex
      sample_attestation.json
```

## Integrating into the iOS app

Once Phase 1E lands, the main app adds this package as a Swift Package
dependency and uses `DCAPVerifier.verify(quote:rootCA:)` in the audit
card flow. The parsed `VerifiedQuote`'s `mrtd`/`rtmr3`/`reportData` are
the inputs to the audit-report assembler; anything that throws becomes
a red row on the audit card.
