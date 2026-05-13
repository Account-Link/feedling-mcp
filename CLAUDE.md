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

1. `docs/CHANGELOG.md` — landmark diffs from recent sessions; this is
   the source of truth for "what shipped, when, why."
2. `DESIGN.md` — if doing any UI work.
3. `deploy/DEPLOYMENTS.md` — if doing any enclave/CVM/on-chain work.

There is no longer a separate HANDOFF.md — it was a session-relay doc
from the v0→v1 strip era and was deleted 2026-05-12. Recent state lives
in the CHANGELOG and in git log.

## Other repo conventions

- TDX enclave operations — cross-reference
  `/Users/sxysun/Desktop/suapp/dstack-tutorial` when something about
  keys/attestation/gateway/TLS is non-obvious.
- Prod user count: **1** (`@sxysun`'s friend, on VPS in multi-tenant
  mode after the 2026-04-20 SINGLE_USER/v0 strip). Migrations + clean
  reinstalls are fair game per task #23.
- `/v1/content/swap` is the ongoing in-place envelope-swap endpoint
  (visibility toggles). There is no v0→v1 migration path anymore;
  plaintext writes now return 400.

## Public docs mirror (io-onboarding)

The three public-facing onboarding docs live in a separate public repo
at `github.com/teleport-computer/io-onboarding`:

- `skill.md`            — agent-facing instructions (fetched by user's MCP client)
- `quickstart.md`       — 5-step setup for human testers (zh + en)
- `troubleshooting.md`  — common failure triage (zh + en)

**These are NOT in this repo anymore.** When a user asks to change any
of those three files, edit them in the local clone of the
io-onboarding repo and push there. The iOS app's `ChatEmptyStateView.skillURL`
constant pins to the raw URL of `skill.md` on `main`, so a push to
io-onboarding is immediately visible to all installed apps (no rebuild
needed for doc updates).

When iterating on agent behavior (e.g. tightening the bootstrap rules)
that is also documented in skill.md, update **both**:
1. The relevant code in this repo (mcp_server.py / app.py / etc.)
2. `skill.md` in the io-onboarding repo

If the user says "update the skill" without specifying, they mean the
public skill.md in io-onboarding.
