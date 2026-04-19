#!/usr/bin/env bash
# publish-compose-hash.sh — compute the current deployment's compose_hash
# and publish it on-chain via the FeedlingAppAuth contract.
#
# Usage:
#   ./deploy/publish-compose-hash.sh <chain>
#
# <chain> must be one of: eth_sepolia | base_sepolia | base
#
# Loads env from contracts/.env (PRIVATE_KEY, RPC URLs, FEEDLING_APP_AUTH_CONTRACT).
#
# What this script does:
#   1. Resolve the compose file path (deploy/docker-compose.yaml by default).
#   2. Compute compose_hash = SHA-256(compose_file_contents).
#        NB: dstack's canonical compose_hash is SHA-256 over app-compose.json,
#        the dstack wrapper manifest. For Phase 1 integration testing we use
#        the raw docker-compose.yaml hash — auditors verifying against our
#        published compose_yaml_url reproduce the same value. Before Phase 2
#        we'll switch to hashing app-compose.json to match dstack's own
#        RTMR3 value exactly.
#   3. Resolve the git commit + GitHub raw URL for this release.
#   4. Call `make add-hash` in contracts/ to publish.
#
# Idempotent: if the hash is already authorized, the Forge script no-ops.

set -euo pipefail

CHAIN="${1:-}"
if [ -z "$CHAIN" ]; then
  echo "usage: $0 <eth_sepolia|base_sepolia|base>" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${FEEDLING_COMPOSE_FILE:-$REPO_ROOT/deploy/docker-compose.yaml}"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "compose file not found at $COMPOSE_FILE" >&2
  exit 1
fi

# Use openssl (BSD + GNU compatible) rather than sha256sum (GNU only)
HASH_RAW="$(openssl dgst -sha256 -binary < "$COMPOSE_FILE" | xxd -p -c 256)"
COMPOSE_HASH="0x${HASH_RAW}"

# Git commit — fail loud if the repo has uncommitted changes to the compose
# file, because that would publish a hash pointing at a commit that doesn't
# actually contain this content.
if ! git -C "$REPO_ROOT" diff --quiet HEAD -- "$COMPOSE_FILE"; then
  echo "ERROR: $COMPOSE_FILE has uncommitted changes." >&2
  echo "       Commit it first, then re-run this script." >&2
  exit 1
fi
GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

# Compose YAML URL pinned to that commit — auditors fetch this to reproduce
# the compose_hash locally.
REMOTE_URL="$(git -C "$REPO_ROOT" config --get remote.origin.url | \
  sed -e 's|\.git$||' -e 's|git@github.com:|https://github.com/|')"
# Cross-platform relative path (BSD realpath on macOS lacks --relative-to).
RELATIVE_PATH="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$COMPOSE_FILE" "$REPO_ROOT")"
YAML_URL="${REMOTE_URL}/raw/${GIT_COMMIT}/${RELATIVE_PATH}"

echo ">>> compose_file : $COMPOSE_FILE"
echo ">>> compose_hash : $COMPOSE_HASH"
echo ">>> git_commit   : $GIT_COMMIT"
echo ">>> yaml_url     : $YAML_URL"
echo ">>> chain        : $CHAIN"
echo

cd "$REPO_ROOT/contracts"
make add-hash CHAIN="$CHAIN" \
  COMPOSE_HASH="$COMPOSE_HASH" \
  COMMIT="$GIT_COMMIT" \
  YAML_URL="$YAML_URL"
