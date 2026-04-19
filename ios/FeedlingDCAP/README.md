# FeedlingDCAP

Swift package: the iOS side of Feedling's on-device attestation auditor.
Parses and (Phase 1E onward) verifies Intel TDX v4 quotes so the iOS app
can confirm what the enclave measured before trusting it with user keys.

See `docs/DESIGN_E2E.md` §5.2 for the role this plays in the overall
architecture.

## Status

**Phase 1 spike:** quote parsing is implemented + tested against a real
TDX quote captured from the dstack simulator. Signature chain
verification (Intel DCAP PCK walk + ECDSA-P256) is stubbed in
`Sources/FeedlingDCAP/Verifier.swift` with implementation notes. That's
the Phase 1E next step.

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
