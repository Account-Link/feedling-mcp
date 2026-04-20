# Migration guide — from self-hosted VPS to Feedling Cloud

If you're reading this, you're on the self-hosted Feedling VPS
(`SINGLE_USER=true`, no enclave) and the team just shipped end-to-end
content encryption on the hosted cloud path. Your data on the VPS is
safe — you own the server — but the new encryption story only kicks
in once you're on the TEE-backed cloud backend.

This doc is the concrete path to get there without losing your
history. Three options; pick the one that matches how you feel about
your data.

---

## Option 1 — Switch to Feedling Cloud (recommended)

Your data ends up re-hosted on the Phala TDX enclave, end-to-end
encrypted under your key. Cost: your agent has to re-add the items
via MCP (it knows how).

### Steps

1. **Install the updated iOS app.** TestFlight link or built from
   source via `testapp/FeedlingTest.xcodeproj`. You'll know you have
   the new build when Settings → Privacy shows a `NavigationLink` row
   at the top rather than the old inline audit card widget.

2. **Settings → Privacy → Export my data.** This pulls down every
   chat, memory, and identity item from your VPS as a single JSON
   file. Save it to Files (On My iPhone), not iCloud Drive — the
   file contains plaintext until the new server re-encrypts it.

3. **Settings → Storage → Feedling Cloud.** This switches the iOS
   app's backend from your VPS to `api.feedling.app`. You'll be
   registered as a new cloud user automatically on the next launch
   (fresh `user_id`, fresh api_key).

4. **Open Settings → Agent Setup → copy the new MCP connection
   string.** Paste it into whichever agent client you use (Claude
   Desktop, Claude.ai, OpenClaw, Hermes). Now your agent is
   connected to your new cloud account.

5. **Hand the export + the new MCP tools to your agent** and ask it
   to re-add everything. A prompt that works:

   > "Here is a JSON export of my old Feedling data. For each entry
   > under `memory`, call `feedling.memory.add_moment` with the
   > title, description, type, and occurred_at. For each entry under
   > `chat` with role=user, skip it (those re-enter naturally as we
   > talk). For identity, call `feedling.identity.init` with the
   > agent_name, self_introduction, and dimensions."

   The agent's writes go through MCP's new envelope wrap — they land
   as ciphertext on the cloud server. Once the agent confirms it's
   done, your new account has your old data, now encrypted.

6. **(Optional) Decommission the VPS.** If you're sure you're done
   with it, you can shut down the old systemd units or the whole
   VPS. The old plaintext data still lives on your VPS disk — if
   that bothers you, wipe the disk or the `~/feedling-data/`
   directory after the re-import.

### Verify

- Settings → Privacy → "Everything you've written is encrypted"
  should tap through to the audit card showing 8/8 green.
- The audit card's "compose_hash" should start with `0xa04608c7…`
  (or whatever the current live version is — see
  `deploy/DEPLOYMENTS.md`).
- `tools/audit_live_cvm.py` from your laptop should print
  `8/8 rows green — ALL PASS` against the live CVM.

### What this buys you

- Content at rest on our server is ciphertext. Backend operators
  can't read your chat, memory, or identity card.
- The enclave's decryption key is bound to a `compose_hash` that
  we've published on-chain — any new version the team deploys is a
  public tx anyone can audit.
- Your iOS app pins the enclave's TLS cert against a fingerprint
  that's signed by Intel's hardware. A MITM swap would be caught.
- You can leave whenever you want. Settings → Privacy → Delete my
  data (with the "download a copy first" checkbox defaulting on).

### What this doesn't change

- Your device still has the plaintext. The Keychain still holds your
  content_sk. If you trust your iPhone + your Apple account, you
  trust the weakest link.
- Frames (screen recordings) follow a separate encryption path — see
  `docs/DESIGN_E2E.md §3` for details.

---

## Option 2 — Stay on self-hosted, update everything

You keep owning the whole stack. No TEE. No encryption at rest on
your VPS. But also: no third party between you and your data.

### Steps

1. `ssh` to your VPS and `git pull --ff-only origin main` in
   `~/feedling-mcp-v1/` (or wherever your install lives).
2. `~/feedling-mcp-v1/backend/.venv/bin/pip install -qr backend/requirements.txt`
   if the lockfile changed.
3. `systemctl --user restart feedling-backend feedling-mcp`.
4. Install the updated iOS app (same TestFlight / Xcode path as
   Option 1).
5. Settings → Privacy → Export my data will still work and hand you
   a tarball. Settings → Privacy → Delete my data will wipe your
   VPS's user directory if you ever want to.

### What this buys you

- Every Phase B privacy UX feature (export / delete / reset UX +
  in-app audit guide link + GitHub repo link) works against your
  own server.
- Your data never leaves your VPS.

### What this doesn't buy you

- Your backend runs as plaintext. If the VPS disk is imaged, leaked,
  or subpoenaed, your content is readable.
- No in-app privacy audit will show 8/8 green (there's no enclave
  to attest) — the audit card will say "TLS is terminated by
  operator-controlled infrastructure."

### When this is the right choice

- You run your VPS in a jurisdiction you trust more than ours.
- You're doing security research and want the whole stack on your
  own hardware.
- You've read the threat model in `docs/DESIGN_E2E.md §10` and
  decided the marginal gains from a TEE aren't worth the "now a
  third party is in the trust graph" cost for you.

---

## Option 3 — Self-hosted with your own TEE

Not worth it for most users, but documented for completeness. You
deploy a Phala dstack CVM yourself and point your iOS app at your
CVM instead of ours. You get the same E2E encryption guarantees as
Option 1 but with your own operator key + release key.

Cost: hours of infra setup, a Phala account with credits, your own
Ethereum contract for `addComposeHash` (or reuse `FeedlingAppAuth`
but you'd be trusting our release key).

If you want to go this route, ping us — the runbook lives in
`skill/SKILL.md` and we're happy to help someone self-host the full
stack.

---

## TL;DR

- **You want E2E encryption + hosted-by-us**: Option 1.
  ~15 minutes, mostly waiting for the agent to re-add items.
- **You want "my data, my server"**: Option 2.
  ~5 minutes, no re-import.
- **You want both**: Option 3.
  half a day of infra. Ping us.

No option here is irreversible. Export is always available; Delete is
always available; Settings → Storage flips between Cloud and
self-hosted freely.
