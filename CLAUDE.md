# CLAUDE.md — repo-level guidance

## Design System

Always read `DESIGN.md` before making any visual or UI decisions.
All font choices, colors, spacing, and aesthetic direction are defined
there. Do not deviate without explicit user approval. If running a
design or QA review, flag any code that does not match `DESIGN.md`.

Concrete rule: no raw hex values, no raw point sizes (except for
display), no raw font strings in Swift view files — use the
`Color.feedling…` / `Font.feedling…` / `Spacing.*` / `Radius.*`
tokens defined at the bottom of `DESIGN.md`.

## Reading order on session start

1. `HANDOFF.md` — where we are right now.
2. `docs/NEXT.md` — the forward roadmap (A → B → C → D).
3. `docs/CHANGELOG.md` — landmark diffs from recent sessions.
4. `DESIGN.md` — if doing any UI work.
5. `deploy/DEPLOYMENTS.md` — if doing any enclave/CVM/on-chain work.

## Other repo conventions

- TDX enclave operations — cross-reference
  `/Users/sxysun/Desktop/suapp/dstack-tutorial` when something about
  keys/attestation/gateway/TLS is non-obvious.
- Prod user count: **1** (`@sxysun`'s friend, on VPS in SINGLE_USER
  mode). Migrations + retirements can be aggressive per task #23.
- iOS auto-migration of legacy plaintext runs on first launch after
  the Phase A.6 update. Don't remove `/v1/content/rewrap` until
  that's confirmed complete.
