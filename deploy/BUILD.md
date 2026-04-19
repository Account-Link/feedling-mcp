# Feedling — Reproducible Build Recipe

This document lets any third party recompute the exact container image
digest that a given git commit produces. It backs the "Reproducible build
recipe published" row in the iOS audit card and the `build_recipe_url`
field in the enclave attestation response.

Every git tag / release commit in the main branch comes with a
corresponding signed build attestation in GitHub Releases containing:

- The base image digest in use (from `deploy/Dockerfile`, `ARG PYTHON_IMAGE=python@sha256:…`)
- The expected output image digest (`sha256:…`) that this recipe should produce
- The sha256 of `deploy/docker-compose.yaml` at that commit (this is the
  plaintext input to the `compose_hash` we publish on-chain via AppAuth)

## Prerequisites

- `docker` ≥ 24
- `uv` ≥ 0.5 (https://docs.astral.sh/uv/)
- a POSIX shell

## Rebuild

```bash
# Clone the exact commit referenced in the on-chain AppAuth event
git clone https://github.com/Account-Link/feedling-mcp.git
cd feedling-mcp-v1
git checkout <git_commit_from_appauth>

# Confirm the pinned base image matches the one in Dockerfile
grep '^ARG PYTHON_IMAGE' deploy/Dockerfile

# Build the image — no cache, so transient layers don't hide drift
docker build --no-cache -f deploy/Dockerfile -t feedling-repro:local .

# Record the digest of the image you just built
docker image inspect feedling-repro:local --format '{{index .RepoDigests 0}}' \
  || docker image inspect feedling-repro:local --format '{{.Id}}'
```

Compare the printed digest against the expected digest published in the
GitHub Release for that commit. If they match, the image you hold is
byte-identical to the one that produced the on-chain `compose_hash`.

## Refreshing pins (maintainers only)

### Base image digest

```bash
# Pull the latest python:3.12-slim
docker pull python:3.12-slim
docker inspect python:3.12-slim --format '{{index .RepoDigests 0}}'
# Copy the sha256:… portion into deploy/Dockerfile ARG PYTHON_IMAGE.
```

### Python dependency lockfile

```bash
# From repo root, regenerate requirements.lock with hashes
uv pip compile backend/requirements.txt \
    --generate-hashes \
    --python-version 3.12 \
    -o backend/requirements.lock

# Commit both requirements.txt (source of truth for what we want) and
# requirements.lock (exact versions + content hashes we ship with).
```

Any change to either pin invalidates the build digest, which invalidates
the compose_hash, which requires a new on-chain `addComposeHash()` +
user-visible audit-card prompt before iOS will talk to the new deployment.

## Known non-determinism

The remaining source of build non-determinism is the apt package set
installed in the base Dockerfile layer (`build-essential`, `libssl-dev`,
`libffi-dev`, `curl`). These are locked to the version available in the
base image's apt sources at build time. Because we pin the base image by
digest and set `--no-install-recommends`, this is deterministic *for that
base image* — but regenerating the base image (Debian sources shift daily)
would produce different apt versions.

For Phase 1 this is acceptable. If auditors insist, the next iteration
would:

- Pin apt packages by exact version (`package=1.2.3-1`)
- Or switch to a fully-static Python distribution (e.g. distroless Python)
- Or use Nix / Bazel for a fully deterministic graph

## Verification script (planned)

`deploy/verify-build.sh` (Phase 2 deliverable): given a git commit and a
GitHub Release digest claim, clones, builds, compares, and emits a signed
attestation. Used by CI and by third-party auditors.
