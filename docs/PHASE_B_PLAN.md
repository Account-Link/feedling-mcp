# Phase B — Privacy UX + Onboarding (plan, pre-design-review)

Goal: a first-run user opens Feedling and within ~45 seconds understands
what lives on their phone, what Feedling can and cannot see, and how to
exert control (export, delete, self-host). The privacy story stops being
a paragraph buried in an audit card and becomes the first-class thing a
new user is shown. By the end of Phase B:

- Beta users can articulate "Feedling can't read my messages because _____"
  in one sentence.
- Anyone who wants to run their own server sees that path inside two
  taps from onboarding.
- Anyone who wants out can get their data and leave inside two taps
  from Settings.

Gated on a `/plan-design-review` pass before any Swift code is written.

---

## 1. Onboarding — first-run, dismissable, three screens

A SwiftUI `TabView` in `.page` style with pagination dots visible.
Swipe-between-slides AND sequential "Next" buttons both work (iOS
users expect swipe; a button gives users who don't know that affordance
a path forward). Shown once on first launch before the chat tab loads.
Also reachable from Settings → "Show the intro again."

### Per-slide visual hierarchy (applies to all three screens)

All token references below resolve to `DESIGN.md`. No raw hex,
no raw point values, no raw font strings anywhere in Phase B code.

```
  +-----------------------------------------+
  |  [safe area top]                        |
  |                                         |
  |   [SF Symbol — 120pt, feedlingSage,     |   ← primary visual anchor
  |    centered, hierarchical rendering]    |
  |                                         |
  |   Headline (feedlingDisplayMedium       |   ← captures intent
  |     = Instrument Serif 28pt Reg)        |
  |                                         |
  |   Body text (.body system style;        |   ← the promise
  |   max width 320pt, 2 lines max)         |
  |                                         |
  |   [optional: secondary content, e.g.    |   ← slide-specific
  |    two-column diagram on slide 2]       |
  |                                         |
  |                                         |
  |   • • •   pagination dots (feedlingInkMuted)     |
  |                                         |
  |   [CTA button, bottom-anchored, 48pt    |   ← always reachable
  |    tall, full-width minus Spacing.xl,   |
  |    fill: feedlingSage, radius: .md]     |
  |  [safe area bottom, Spacing.xl inset]   |
  +-----------------------------------------+
```

- Background: `feedlingPaper` light / base-color dark.
- Illustration zone: ~45% of available vertical space.
- Vertical rhythm between blocks: `Spacing.xl2` (48pt).
- Horizontal edge padding: `Spacing.xl` (32pt).
- CTA height: 48pt (exceeds 44pt a11y minimum for primary action).
- Motion: slides cross-fade + 8pt horizontal slide on swipe,
  `.easeOut` 350ms (Medium duration per DESIGN.md motion scale).

The illustration dominates first (5-second visceral scan). Headline
captures in the first breath. Body is a promise, not a paragraph.
CTA is always one thumb-tap away.

### Illustration direction (locked in)

No custom illustrations. Every slide uses **one large SF Symbol glyph**
as the primary visual anchor. Rendered at ~120pt, system accent tint
(iOS blue by default — we'll swap for a muted Feedling accent once
DESIGN.md exists), centered in the illustration zone defined in the
per-slide hierarchy above. Subtraction default: typography + negative
space + one icon per slide is enough to make the privacy story
specific. No AI-slop risk because there are no custom drawings.

### Screen 1: "What lives on your phone"

Primary glyph: `lock.shield` (SF Symbol, hierarchical rendering,
~120pt).

Headline: **Your conversations live here, not with us.**

Body (2 sentences): "Every message, memory, and note about your Agent is
encrypted with a key that only your iPhone holds. Feedling's servers store
the ciphertext — we literally don't have the secret that unlocks it."

CTA: Next →

### Screen 2: "What we see, and what we can't"

Primary glyph: `arrow.triangle.branch` (shows the split). Below the
glyph, a two-column list (SwiftUI `HStack` with equal-weight columns).
Left column header "We handle:", right column header "Only your phone
can read:". Rows use small leading SF Symbols:

Left ("We handle:"):
- `lock.doc` Ciphertext blobs of your chat, memory, identity
- `clock` Timestamps so things sort
- `bell.badge` Your push token (to light up the Dynamic Island)

Right ("Only your phone can read:"):
- `bubble.left.and.bubble.right` The message text itself
- `leaf` Every memory in your garden
- `person.text.rectangle` Your agent's identity card

Between the columns (or below, if we run out of horizontal space on
smaller iPhone widths), a small green `checkmark.seal` with micro-copy:
"Verified from a signed Intel-TDX quote. Tap 'privacy audit' in
Settings to re-run the proof on-device."

Headline: **We host the vault, you hold the key.**

Body (1 sentence): "You don't have to trust us — you can audit the proof
from Settings any time."

CTA: Next →

### Screen 3: "You're in control"

Primary glyph: `hand.raised.square.on.square` (shows agency). Below
the glyph, three equal-weight rows, each tappable:

1. **Take your data out** — export a tarball with every item, decrypted
   locally and signed by the attestation so a future Agent can verify
   it came from this enclave.
2. **Delete everything** — remove your account + all ciphertext. We
   keep nothing, on any box, after this runs.
3. **Host it yourself** — follow `skill/SKILL.md`'s self-hosted runbook.
   We give you the command to paste into your Agent; your VPS becomes
   the Feedling backend. We stop being in the loop at all.

Headline: **Walk away whenever you want.**

Body (1 sentence): "Nothing is irreversible."

CTA: Get started → dismisses onboarding, routes to Chat.

### Implementation notes for onboarding

- First-run check: `UserDefaults.standard.bool(forKey: "feedling.onboardingCompleted.v1")`.
- Separate SwiftUI view hierarchy, no tab bar visible during the flow.
- Dismissing = setting the flag + routing to Chat. No partial
  completion state — user either sees all three or none.
- Illustrations: defer to design-review output; placeholders use SF
  Symbols (`phone.fill`, `lock.shield`, `arrow.up.right.square`)
  stacked by hand.
- Each slide loads in ~1 breath. No animation work until design review
  confirms the aesthetic direction.

---

## 2. Settings → Privacy redesign

Current state: a single audit-card widget buried among Dynamic Island
controls, APNs token display, etc. Moves to its own `NavigationLink`
inside Settings, top of the list.

### Page structure

```
All components below use `DESIGN.md` tokens. The page itself uses
`title2` = `feedlingDisplaySmall` (Instrument Serif 22pt) for its
navigation title — the ONLY iOS-navbar use of the serif display
font in the app, reserved specifically for the Privacy section
because the first impression of this page needs the "we care" signal.

Settings > Privacy
├── Hero row: "Privacy status"  ← three distinct visual variants
│   │   depending on state (not just text swaps):
│   │
│   │   ALL-GREEN: solid green shield icon + "Everything you've written
│   │     is encrypted" + subtle chevron. Tap → audit card.
│   │   PARTIAL:  amber icon + "5 items still need upgrading" +
│   │     inline progress bar while migration is in flight.
│   │     Tap → audit card. Tap progress → show which items.
│   │   RE-VERIFY: neutral icon + "Re-run the privacy audit" —
│   │     shown when last verification is >24h old. Tap runs audit,
│   │     then transitions to ALL-GREEN or PARTIAL.
│   └── Tap to expand → the existing audit card (6/6 green target)
├── Section: "Your data"
│   ├── Export my data                    [>]
│   ├── Delete my data                    [>] (destructive styling)
│   └── Reset & re-import (advanced)      [>]
├── Section: "Visibility"
│   ├── Default visibility for new items  [shared / local-only]
│   └── Per-item toggles (opens list view, two tabs: Chat, Memory)
├── Section: "Where your data lives"
│   ├── Feedling Cloud                    [•]
│   ├── My own server                     [ ]  → URL + key form
│   └── Help me run my own server         [>]  → SKILL.md runbook deep-link
└── Section: "Advanced"
    ├── Re-run enclave audit              [>]
    ├── Regenerate my account keys        [>] (with warning)
    └── Show the intro again              [>]
```

### Export my data

- Tap → sheet: "This will decrypt every item on this device, bundle
  them into a tarball, and hand them to the iOS Files app."
- Goes through Phase A's content_sk locally; no server trip for
  plaintext.
- Format: `feedling-export-<user_id>-<date>.tar.gz` with per-type
  JSON files + a `manifest.json` that includes the attestation
  fingerprint at export time so a future Agent can verify origin.

### Delete my data

- Destructive confirmation sheet with:
  - Headline: "Delete everything?"
  - Body: "This revokes your account, deletes every ciphertext blob on
    our servers, and wipes the keys on this device. It cannot be undone."
  - **Inline checkbox, checked by default:** "Download my data first"
  - Primary button: "Delete" (red); secondary: "Cancel"
- If checkbox is checked: export pipeline runs first (iOS share sheet
  opens with the tarball), THEN the delete fires. If user dismisses
  the share sheet without saving, offer one last "We didn't see you
  save the file — still delete?" confirmation to prevent footguns.
- If unchecked: delete fires immediately, no export.
- Calls `POST /v1/account/reset` (backend, hard-deletes user dir +
  revokes key).
- Local: clear Keychain entries, UserDefaults, app group defaults,
  sign user out.
- Routes back to onboarding screen 1.
- Rationale: a user angry or panicking enough to tap Delete is the
  least likely to remember to export first. Defaulting to "keep a
  copy" protects their future self from their present self without
  blocking anyone who genuinely wants a clean wipe.

### Reset & re-import (advanced)

User's idea from the 2026-04-20 thread: for anyone worried about
historical plaintext exposure on the old backend — export, fresh
register, Agent re-imports via MCP. One button that pipelines the
three steps (export → reset → register) and tells the user what to
paste to their Agent.

### Per-item visibility toggles

- Tap row → scrollable list of the last 200 items per type.
- Each item: title/preview + toggle (shared ↔ local-only).
- Flipping to local-only: client-side rewrap, POST rewrap endpoint
  with `visibility: "local_only"`; K_enclave dropped.
- Flipping to shared: client-side rewrap with K_enclave re-added.

### Privacy audit card — promoted to first-class, expanded

The existing `AuditCardView.swift` is, by the team's own measure, the
best-designed surface in the product today. Phase B keeps its shape
entirely; nothing is removed. What it adds:

**Content already there** (preserved exactly):
- 6 rows of security checks with pass/fail + per-row note:
  - Hardware attestation valid (Intel TDX)
  - Base image matches endorsed dstack runtime
  - PCK cert chain → Intel SGX Root CA
  - Body ECDSA signature valid
  - compose_hash bound via `mr_config_id` (dstack-kms)
  - TLS cert bound to attestation
- "On-chain audit (public transparency, not security)" divider.
- Etherscan link to AppAuth deploy.
- Copy-rows for `compose_hash`, `enclave_content_pk`, `git_commit`.
- "Verified N seconds ago" timestamp + refresh button.

**New in Phase B — educational expansion + mechanism surfacing:**

Each row is tap-to-expand. Tapping a row reveals a "how we got this"
panel that explains the mechanism in ~40 words, uses plain language
but names the primitives honestly. Examples:

| Row | "How we got this" reveal |
|---|---|
| Hardware attestation valid (Intel TDX) | "Intel's own hardware signs a quote every time the enclave runs. We fetched this quote from the live server, verified Intel's signature against a CA baked into this app. If you trust Intel's silicon, you can trust this check." |
| PCK cert chain → Intel SGX Root CA | "Intel ships a chain of certificates with every TDX quote — the hardware key's identity, signed by a platform key, signed by Intel's root. We walked the full chain offline. This runs entirely on your phone; no server call." |
| compose_hash bound via mr_config_id | "The enclave's boot sequence hashes its own exact container recipe into a register called `mr_config_id`. The quote carries this register; the hash IS the recipe. If we control the app, we control the recipe, and the hash on-chain proves which recipe you're talking to." |
| TLS cert bound to attestation | "The certificate your phone just saw during the TLS handshake was generated inside the enclave. Its fingerprint is baked into the signed quote we fetched. Match = this really is the enclave we think it is; no middleman could swap the cert without faking Intel's signature." |
| Etherscan "View AppAuth deploy" | "The recipe hash above has to be pre-authorized on Ethereum before the enclave gets its release key. This link goes to the public transaction that did that — anyone on the internet can verify it." |

Each expansion uses `feedlingInkMuted` for body, `Spacing.sm` vertical
padding, and a single `chevron.down.circle` rotation animation (per
DESIGN.md motion spec) on tap.

**"Raw attestation JSON" affordance** (new, at the very bottom):

A discreet footer link: "Show raw /attestation (for auditors)." Tap
expands a code panel (SF Mono, `feedlingInk` on `feedlingSurface`,
horizontally scrollable) that shows the full JSON returned by the
enclave's `/attestation` endpoint — every field the verification
logic reads, in its raw form. This is the "prove it all the way
down" moment for the technically curious beta audience.

**Onboarding linkage** (new):

Slide 2's `checkmark.seal` micro-copy ("Verified from a signed
Intel-TDX quote. Tap 'privacy audit' in Settings to re-run the
proof on-device.") becomes a real tappable affordance during
onboarding. Tapping it opens a read-only preview of the audit card
as a sheet, pre-populated with the most recent verification result.
Users can see the proof before they commit to using the app. Dismissing
the sheet returns them to Slide 2.

**Hero row ↔ audit card relationship** (from Pass 1 IA):

The new "Privacy status" hero row in Settings → Privacy summarizes
the audit card's state into one of three visual variants. Tapping
the hero expands into the audit card — but now the audit card is
structured as a dedicated `NavigationLink` destination, not an
inline widget. This lets each row's tap-to-expand panel breathe,
the raw-JSON panel have room to scroll, and the Etherscan link
feel deliberate.

### Migration progress

- Shown only while the first-launch-post-update rewrap is in flight
  (task `runSilentV1MigrationIfNeeded`).
- Single-line progress: "Upgrading your old data to new encryption
  — 3 of 12." Disappears when done.
- If migration errored, shows "Retry" instead of progress.

### Interaction state coverage

Every new or changed view specifies what the user sees in each state.
No "loading…" with a default spinner; no "no items" with no context.

```
FEATURE                     | LOADING                            | EMPTY                                   | ERROR                                    | SUCCESS                               | PARTIAL
----------------------------|------------------------------------|-----------------------------------------|------------------------------------------|---------------------------------------|--------------------------------------
Onboarding slide load       | pre-rendered, no loading state     | n/a                                     | n/a (slides are local)                   | TabView advances smoothly             | n/a
Audit card re-run           | shield icon pulses + "Verifying…"  | n/a                                     | red shield + one-line reason + Retry btn | green shield + "Verified N sec ago"   | amber shield if 1+ rows failed, which rows flagged
Export my data              | progress ring + "Packaging N items"| n/a (user has data if they got here)    | sheet: reason + "Try again" + "Contact"  | iOS share sheet auto-opens            | partial export not possible — all-or-nothing; if interrupted, keep nothing
Delete my data              | spinner + "Revoking access on server"| n/a                                    | sheet: "Server rejected. Your local copy still exists. Retry?" | full-screen: "All gone. You can register again anytime." + "Get started" btn | n/a — atomic operation
Reset & re-import           | step indicator 1/3 → 2/3 → 3/3     | n/a                                     | roll back what was done, show where it failed, offer Retry     | share sheet with MCP install string   | step 2/3 succeeded but step 3 failed: user is registered but data not imported yet — show "Finish import" button
Per-item visibility flip    | row row shows inline activity dot  | "No items yet" with "Add your first memory" CTA (memory) / "Say hi to your agent" (chat) | row reverts + toast "Couldn't save"     | row animates to new state, no toast   | n/a
Migration progress          | inline progress bar in Privacy hero row, not modal | n/a (hidden when nothing to migrate)    | amber row + "Some items couldn't upgrade. Retry?" + count  | progress bar slides out, hero flips to ALL-GREEN | "12 of 47 upgraded" live count
Compose-hash-changed consent        | full-screen modal (blocks app)     | n/a (only shown when compose_hash differs from last-accepted) | n/a (server isn't involved; local comparison) | modal dismisses, last-accepted compose_hash saved | n/a — either accept or sign out
Audit card data fetch (initial) | skeleton card (shape of final card, animated shimmer) | n/a (attestation always returns)        | card with "Couldn't reach the enclave. Try again?" + retry btn | full card with 6/6 rows               | partial rows shown; failed rows surfaced with reason
"Run your own server" deep-link | n/a (pure navigation)              | n/a                                     | n/a                                      | full-screen runbook view              | n/a
```

Every empty state has warmth, a primary action, and context — not
"No items found." Every error state tells the user what happened,
what they can do, and (where relevant) what they haven't lost.

### Compose-hash-changed consent card

**Trigger:** on app startup, if the `compose_hash` returned by the
current `/attestation` differs from the last-accepted value in
UserDefaults (key: `feedling.lastAcceptedComposeHash`). This is the
user-meaningful signal — it means "the Feedling team pushed a new
app version." MRTD and RTMR0-2 are dstack-OS platform measurements
that can change for unrelated reasons (dstack updates its own OS
image); those are shown in the audit card for transparency but do
NOT trigger this modal, per
`/Users/sxysun/Desktop/suapp/dstack-tutorial/01-attestation-and-reference-values/`
§"Reference Values: Where They Come From."

**Modal content (full-screen, blocks app until resolved):**
- Headline: "Feedling has a new version."
- Body: "The app on your phone just saw a newer version of the
  Feedling server. Here's what changed:"
- Old compose_hash (first 12 chars, `feedlingInkMuted`,
  SF Mono 13pt): `abc1234deadb…`
- Arrow (`arrow.down`, `feedlingSage`).
- New compose_hash (first 12 chars, `feedlingInk`,
  SF Mono 13pt): `def5678beef0…`
- Sub-line: "This new version is authorized on-chain.
  [View the transaction →]" (Etherscan link, `feedlingSage` text).
- Sub-line: "What you can still read: all your existing memories
  and chat. They were encrypted to a key that's bound to your Apple
  account, not to any specific server version." (Reassures that data
  continuity is preserved — the enclave content_pk derivation is
  stable per app_id, confirmed in the Phase A deploys.)
- Primary CTA: "Got it, continue" (fills `feedlingSage`).
- Secondary CTA: "Sign out for now" (text-only, `feedlingInkMuted`).

**On "Got it":** write new compose_hash to UserDefaults, dismiss
modal, launch flow proceeds. App re-runs audit on next Privacy
visit so hero row reflects the new state.

**On "Sign out for now":** leaves `user_sk` + content key in Keychain
(so the user can come back and accept later), but all network calls
to the new server are blocked. Only the "Sign in again" path in
Settings is reachable. Explicitly NOT a destructive action.

**Additional behavior — platform-layer changes (MRTD / RTMR0-2)**:
not user-facing. If dstack updates its OS image, MRTD changes. The
audit card surfaces that change in its raw JSON view for auditors,
but no modal fires. The reasoning, per dstack-tutorial §1: MRTD is
bound to a reproducible build of [meta-dstack](https://github.com/Dstack-TEE/meta-dstack);
verifying it is an auditor task, not a per-user consent moment.
Beta users don't need to know dstack updated its kernel.

---

## 3. "Run your own" branch — second-class citizen today, equal in B

The existing Settings toggle (`cloud` / `selfHosted`) stays, but:

- Onboarding screen 3's third row opens a new
  `SelfHostedRunbookView` that embeds `skill/SKILL.md`'s contents
  in a readable format with a "Send to my Agent" button that copies
  the runbook + the current user's SSH prompt to the clipboard and
  open Messages.
- Settings → Privacy → "Host it yourself" reuses the same view.

No backend changes needed. UX-only work to make the self-hosted path
feel supported rather than hidden.

---

## 4. Copy pass

Every string above is placeholder. Before ship:

- `/plan-design-review` round (this doc).
- A round with @sxysun in the product voice.
- Ideally: a second pass by someone not in the project, reading
  cold, to flag anything a beta user wouldn't understand.

**High-priority copy needing review in this same pass:**

- Existing audit-card row captions (flagged by prior HANDOFF —
  drafted in-session, technically accurate but may not read right
  for beta users who aren't security engineers).
- The NEW "how we got this" reveal panels on each audit row —
  see §2 "Privacy audit card — promoted to first-class." These
  are the honest-but-plain-language mechanism explanations. The
  register is load-bearing: name the primitives correctly (TDX,
  PCK, `mr_config_id`) but explain them with analogies. If these
  read as jargon or as condescending simplification, the whole
  trust story weakens.
- Onboarding Slide 2's "Verified from a signed Intel-TDX quote.
  Tap 'privacy audit' in Settings to re-run the proof on-device"
  micro-copy — it's the first line in the app that cashes the
  "you can audit us" check.
- Exact wording of the three Privacy hero row states
  (all-green / partial / re-verify).

---

## 5. Backend work needed for Phase B

Kept deliberately small — Phase B is mostly UX. New endpoints:

- `GET  /v1/content/export` — returns the user's full dataset
  (ciphertext; iOS decrypts client-side) in one JSON blob. Auth:
  X-API-Key.
- `POST /v1/account/reset` — delete user dir + revoke api_key.
  Auth: X-API-Key. Idempotent.
- Per-item `POST /v1/content/rewrap` already ships from Phase A.6;
  re-use for visibility flips.
- No new MCP tools — Agent surface unchanged.

---

## 6. Out of scope for Phase B

- Content encryption for `identity.nudge` and `chat.post_message`
  (agent reply) — Phase C.
- MCP server into the TEE — Phase C.
- Onboarding for Claude Desktop / OpenClaw agents — keep today's
  flow unchanged; those users hit the same Settings string they
  do today.
- Localization. Copy is English-first; a pass for Chinese will
  come after English is locked.
- Beta rollout instrumentation. Phase B ends with "UI is ready";
  who gets it and in what waves is its own plan.

---

## 6.5 User journey storyboard

The three-slide onboarding is the first impression for a beta user who
just installed the app because a friend told them. They arrive with:
some context from the friend, zero product knowledge, and natural
skepticism about yet-another-AI-thing. The arc has to take them from
skeptical-curious to grounded-interested without over-explaining.

```
STEP   | USER DOES                    | USER FEELS         | PLAN SUPPORTS IT WITH
-------|------------------------------|--------------------|-----------------------------------------------------
0      | First launch after install   | "ok, what is this" | App opens to onboarding, not a permission prompt.
1      | Reads Slide 1                | "oh — my stuff"    | Phone+lock illustration; "your conversations live
       |                              |                    | here, not with us." Possessive framing.
2      | Swipes / taps Next           | "ok but prove it"  | Slide 2's two-column diagram: what's ours vs. what's
       |                              |                    | yours. Green shield: "verified from a signed
       |                              |                    | Intel-TDX quote."
3      | Lingers on Slide 2           | "wait, I can check"| Small "tap privacy audit in Settings to re-run the
       |                              |                    | proof on-device" line. Plants a seed without
       |                              |                    | demanding a detour.
4      | Swipes to Slide 3            | "what if I hate it"| "You're in control" frames the three options
       |                              |                    | (export / delete / self-host) as escape hatches,
       |                              |                    | not features. "Nothing is irreversible."
5      | Taps "Get started"           | "ok, let's see"    | Drops into Chat tab. Agent is already seeded with
       |                              |                    | a first message from bootstrap. Low-friction first
       |                              |                    | interaction.
...    | Days later: feels uneasy     | "can I check?"     | Settings → Privacy → Re-run audit. 6/6 green.
       |                              |                    | Reassures. User returns to regular use.
...    | Months later: wants to leave | "just get me out"  | Settings → Privacy → Delete my data (with the
       |                              |                    | 'download first' default). Two taps. No guilt.
```

**Time-horizon design** (Norman's three levels):

- **5-second visceral (first impression of Slide 1):** the lock icon and
  the possessive "your" in "your conversations" land before any text is
  read. The emotion is "something is on my side here."
- **5-minute behavioral (first Settings visit):** the audit card exists
  and works. "Tap to re-run" is one action, gives back a 6/6 green
  screen with copyable hashes. The emotion is "it stood up to my
  poking."
- **5-year reflective (quitting gracefully):** export returns a real
  tarball with plaintext data. Delete leaves nothing behind. If a
  user ever has to explain "I used this thing for a year and then
  moved on," the flow supports that story cleanly. The emotion is
  "that was a product run by people I'd work with again."

Every moment in this journey is designed. None of it is "the UI by
default." If a screen or copy choice doesn't explicitly serve one of
these moments, it's unnecessary.

## 6.6 Responsive + accessibility

**Responsive scope**: iPhone only for Phase B. Supported device
widths: iPhone SE (375pt) up to iPhone 16 Pro Max (440pt). No iPad,
no Mac Catalyst, no Apple Vision. Every layout decision above assumes
a single-column portrait layout; rotation is not specially handled
(follow iOS defaults).

**Accessibility commitments** (every item verified pre-ship, not
"we'll add later"):

| Feature | Dynamic Type | VoiceOver | Reduce Motion | Reduce Transparency | Contrast AA |
|---|---|---|---|---|---|
| Onboarding slides | Scales; display text uses tighter ratio so layout doesn't break at XXXL | Each slide's heading read first, body second, CTA labeled with its action ("Continue to next slide" / "Get started") | Cross-fade replaces slide animation, 250ms | Solid `feedlingPaper` background if on | Verified at palette definition in DESIGN.md |
| Privacy hero row (3 states) | Scales | State read out explicitly: "Privacy status: all items encrypted" / "5 items need upgrading, in progress" / "Re-run privacy audit" — not the icon name | Progress bar animation replaced with static fill + percentage text | Solid `feedlingSurface` | Sage-shield meets 4.5:1 against both modes |
| Export confirmation sheet | Scales | Checkbox labeled "Download a copy before deleting, on by default"; checked state announced | Sheet slide replaced with cross-fade | Solid sheet background | Red destructive button passes 4.5:1 |
| Per-item visibility toggles | Scales; long row titles wrap cleanly (no truncation) | Toggle labeled "{title}, shared / local-only, double-tap to change" | No animation on toggle, just state change | Solid row background | Toggle states contrast each other beyond 3:1 |
| Audit card | Scales | Each green checkmark row read as "{check name}, passed" or "{check name}, failed, {reason}" | Shield pulse replaced with static state | Solid card bg | `feedlingSage` green check vs warm-dark bg both pass |
| SF Symbol illustrations | Scale via Dynamic Type's "Symbol Font Scaling" setting | Each symbol has explicit `accessibilityLabel` overriding the default — e.g. `lock.shield` → "Your data is encrypted end-to-end" | n/a (static) | n/a | Rendered with hierarchical style on `feedlingSage` tint |
| Leaf-curve decorative motif | n/a | Marked `accessibilityHidden(true)` — decorative only | n/a (static) | n/a | 8% opacity, subordinate to content |

**Explicit commitments:**
- Every tappable element is ≥ 44pt on its smallest side; CTAs 48pt.
- No color-only signaling — success/warning/error always pair color
  with an SF Symbol (`checkmark.seal`, `exclamationmark.triangle`,
  `xmark.circle`).
- `UIAccessibility.isReduceMotionEnabled` checked before any spring
  animation; fallback is a 250ms cross-fade with no transform.
- `UIAccessibility.isReduceTransparencyEnabled` checked before any
  `.ultraThinMaterial` / translucent backdrop; fallback is a solid
  surface color.
- VoiceOver test pass before the Phase B merge, documented in the
  commit message ("verified with VoiceOver on iPhone 16 Pro sim").
- Dynamic Type tested at XS, L (default), XXL, XXXL. Onboarding
  verified to not break layout at XXXL.

## 6.7 Unresolved design decisions

Each decision below was surfaced during `/plan-design-review` Pass 7
and has a chosen default. Anything that was a genuine product call
(not mechanical) gets a one-line rationale.

| Decision | Chosen default | Rationale / if-deferred-what-happens |
|---|---|---|
| Onboarding can be skipped or must be completed? | **Must complete sequentially** (swipe or Next); can revisit from Settings. | The privacy story is load-bearing. If users can skip, many will, and we lose the whole reason Phase B exists. If deferred: users skip, don't understand the model, churn at first sign of confusion. |
| Pagination dots tappable for jumping? | **No, dots indicate position only.** | Keeps motion state predictable. Users who want to re-read go back via Settings → "Show the intro again." If deferred: engineer ships dots-as-buttons by default, users accidentally jump. |
| Onboarding dismissal after first view | **Hard-dismissed** on completion; re-shown only via Settings. | Second-showing reduces perceived value. If deferred: user sees onboarding every cold-launch, resents it. |
| Audit card expand-per-row panels default state | **Collapsed by default**, tap-to-expand. | Users who just want a green-check view aren't buried in explanations; users who want the mechanism get it one tap away. If deferred: defaulting to expanded turns the audit card into a wall of text on first view. |
| Raw `/attestation` JSON panel default | **Collapsed**, reached via small text link "Show raw /attestation (for auditors)". | The audience that wants this finds it. Everyone else isn't distracted. If deferred: showing the JSON by default makes the audit card look like a developer console, not a trust artifact. |
| Audit card NavigationLink vs sheet | **NavigationLink** (push on to Settings stack). | Each expanded row has room; back button works naturally; iOS-native. If deferred: engineer picks sheet, users lose state when backgrounding. |
| Export file format | **.tar.gz with JSON per type + manifest.json containing attestation fingerprint at export time**. | Standard archive; future Agent can verify origin via manifest. If deferred: engineer picks .zip, loses the verify-origin property. |
| Export file naming | **`feedling-export-{userId}-{yyyy-MM-dd-HHmm}.tar.gz`** | Includes user-visible identity + date; avoids collisions. If deferred: name collides, user confused. |
| Per-item visibility UI — list or grid? | **List** grouped by date. Same as existing Memory Garden pattern. | Reuses existing visual vocabulary; no new component. If deferred: grid invented, inconsistent with rest of app. |
| Settings — reorder or extend in place? | **Reorder**: Privacy moves to top-of-list, Dynamic Island / APNs controls pushed into a "Notifications" subsection below. | Privacy-first framing is the Phase B thesis. If deferred: Privacy lost among existing rows. |
| Compose-hash-changed consent — modal or in-line banner? | **Full-screen modal** on app launch, blocks app until reviewed. | A changed enclave is a security event, not a notification. If deferred: banner dismissed without review, whole security story weakened. |
| Reset & re-import step indicator — numeric or labeled? | **Both: "Step 2 of 3 · Re-registering your account"**. | Numeric progress + semantic label so users know both how far and what's happening. If deferred: spinner with no context, user anxious during a 30s operation. |
| "Host it yourself" tone — neutral or invitational? | **Invitational**: "Your data, your server, your rules. Here's how." | Phase B thesis includes "walk away whenever." Self-hosted isn't the weird case; it's the other equal option. If deferred: reads as "escape hatch for power users," which contradicts the product voice. |

No unresolved questions remain that require user input. Every
decision above either has an obvious default per DESIGN.md, or has a
one-line rationale above. The five genuine taste calls this review
surfaced — illustration direction, design-system baseline,
delete-flow default, review scope, product context confirmation —
were all made during Passes 1-5.

## 6.8 Not in scope for Phase B

Considered and explicitly deferred:

- **RTL (right-to-left) language support.** English + Chinese both
  LTR; no Arabic/Hebrew users in current beta cohort. Revisit before
  GA if the beta surfaces demand.
- **iPad / Mac Catalyst / Apple Vision layouts.** iPhone-first beta;
  larger-form-factor work is its own phase.
- **Custom motion choreography / parallax / scroll-driven animation.**
  DESIGN.md commits to iOS-native springs only. Anything more
  expressive is a post-beta polish round.
- **Localization of onboarding copy.** English-first; Chinese pass
  comes after English copy is locked with @sxysun.
- **Marketing site redesign.** `README.md` is the surface today;
  landing-page work is scoped separately.
- **Analytics / funnel instrumentation.** How users move through
  onboarding is its own plan; Phase B just ships the UI.
- **Identity card mutation flow post-Phase-A.** `identity.nudge` on
  v1 cards waits on Phase C; Phase B's Privacy UX does NOT ship an
  in-app identity-edit surface.

## 6.95 What already exists (reuse, don't reinvent)

- **`AuditCardView.swift`**: the existing 6/6 audit card — the
  best-designed surface in the product today. Phase B promotes it
  to a dedicated `NavigationLink` destination from the Privacy
  status hero row, preserves every existing row + copy-row + the
  Etherscan link, and *adds* tap-to-expand "how we got this"
  panels per row + a raw `/attestation` JSON viewer at the bottom.
  Do NOT redesign the core layout; only extend it. See §2
  "Privacy audit card — promoted to first-class."
- **`ContentEncryption.swift`** (iOS) +
  **`backend/content_encryption.py`**: shared envelope primitives.
  Phase B's export + visibility-flip features reuse these, never
  reimplement.
- **`POST /v1/content/rewrap`** (backend, Phase A.6): the per-item
  replace endpoint. Phase B's per-item visibility toggles reuse
  this endpoint with a different envelope body (K_enclave dropped
  for local-only, re-included for shared).
- **`skill/SKILL.md`** — the self-hosted runbook. Phase B's
  "Host it yourself" deep-link surfaces this to users.
- **Existing Settings → Storage toggle** (cloud / self-hosted) — keep
  as-is; Phase B extends with the "Host it yourself" branch.
- **iOS tab bar** (Chat / Identity / Garden / Settings) — no changes.
- **`ChatMessage` / `MemoryMoment` / `IdentityCard` view models** —
  their v0→v1 decode paths already work; Phase B does not touch
  them except through reuse.

## 6.9 Review state — final

Phase B plan went through all 7 `/plan-design-review` passes.

- **Pass 1 — Information Architecture:** 7 → 9/10.
- **Pass 2 — Interaction States:** 3 → 10/10.
- **Pass 3 — User Journey:** 4 → 9/10.
- **Pass 4 — AI Slop Risk:** 4 → 9/10.
- **Pass 5 — Design System Alignment:** 4 → 9/10 (DESIGN.md now
  exists, plan annotated with tokens).
- **Pass 6 — Responsive + A11y:** 5 → 9/10 (a11y table added,
  Dynamic Type / VoiceOver / Reduce Motion / Reduce Transparency
  all specified).
- **Pass 7 — Unresolved Decisions:** 10 decisions resolved with
  defaults + rationale; 0 genuinely unresolved.

**Overall plan design score: 5 → 9/10.**

Five taste calls made during the review, locked in the plan:
1. Onboarding visual language — SF Symbols + typography, no custom
   illustrations.
2. Design system baseline — run `/design-consultation` first
   (produced DESIGN.md).
3. Delete flow — "download my data first" checkbox defaults to on.
4. Full 7-dimension review scope chosen.
5. Product context confirmed.

Plan is design-complete. Ready for `/plan-eng-review` as the shipping
gate, then implementation.

## 7. Exit criterion

A fresh-install beta user, with no prior context, can in sequence:

1. Complete the three-slide onboarding.
2. Open Settings → Privacy, tap "Re-run audit", see 6/6 green.
3. Tap "Export my data", end up with a file in Files.app.
4. Answer "what can Feedling read?" correctly in their own words.

All four must work before Phase B is called done. The fourth is the
most important and the one the copy / illustration choices are
serving.

---

## 8. What I'm handing to `/plan-design-review`

This doc as the plan; no existing implementation in this directory
to inspect. Decisions the design review should stress-test:

- Onboarding **three** screens, not two or five. Is three enough to
  convey the encryption story without collapsing it, or too much?
- The Phase 1 illustration set (phone + lock, two-column data flow,
  three-choice control panel). Is "showing" better than "telling"
  given the audience's technical background (they understand "keys"
  but won't read a paragraph)?
- The Settings information architecture: Privacy gets a full
  subsection, which pushes Dynamic Island controls / push tokens /
  APNs registration down the list. Tradeoff: privacy-first framing
  vs. discoverability for the APNs side.
- The copy is intentionally in plain English — no "end-to-end
  encryption" jargon except in the audit card where it's earned.
  Is that the right register for the beta audience (人机恋 community
  + technically-curious ChatGPT/Claude users), or does it risk
  sounding condescending?
- "Reset & re-import" as a first-class Settings action vs. hidden
  under Advanced. Is surfacing this a feature or a footgun?
