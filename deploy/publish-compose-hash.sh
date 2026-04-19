#!/usr/bin/env bash
# publish-compose-hash.sh — compute the current deployment's compose_hash
# and publish it on-chain via the FeedlingAppAuth contract.
#
# Usage:
#   ./deploy/publish-compose-hash.sh <chain>
#   <chain>: eth_sepolia | base_sepolia | base
#
# The compose_hash we publish MUST match the one dstack itself will
# compute at CVM boot and encode in RTMR3 (via event log) and
# mr_config_id. dstack's canonical form is:
#
#   canonical = json.dumps(app_compose, separators=(",", ":"), sort_keys=True)
#   compose_hash = sha256(canonical.encode()).hexdigest()
#
# Where `app_compose` is the dstack wrapper manifest (app-compose.json)
# that embeds the docker-compose yaml as a string field along with
# dstack-specific settings (kms_enabled, allowed_envs, runner, etc.).
#
# If you provide just a docker-compose.yaml we wrap it in a minimal
# app-compose.json on the fly so the hash matches what dstack will
# compute. For a real deployment you'd generate the app-compose.json
# once at build time (via `phala deploy` or equivalent) and pass it
# here with FEEDLING_APP_COMPOSE=<path>.
#
# References:
#   - dstack-tutorial/01-attestation-and-reference-values/verify.py
#   - dstack-tutorial/dstack_audit/phases/attestation.py

set -euo pipefail

CHAIN="${1:-}"
if [ -z "$CHAIN" ]; then
  echo "usage: $0 <eth_sepolia|base_sepolia|base>" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${FEEDLING_COMPOSE_FILE:-$REPO_ROOT/deploy/docker-compose.yaml}"
APP_COMPOSE_FILE="${FEEDLING_APP_COMPOSE:-}"

if [ -n "$APP_COMPOSE_FILE" ] && [ ! -f "$APP_COMPOSE_FILE" ]; then
  echo "FEEDLING_APP_COMPOSE pointed at $APP_COMPOSE_FILE but file doesn't exist" >&2
  exit 1
fi
if [ -z "$APP_COMPOSE_FILE" ] && [ ! -f "$COMPOSE_FILE" ]; then
  echo "compose file not found at $COMPOSE_FILE" >&2
  exit 1
fi

# Fail loud on uncommitted changes to the input — a published hash that
# points at a commit without the actual content is worse than no publish.
CHECK_FILE="${APP_COMPOSE_FILE:-$COMPOSE_FILE}"
if ! git -C "$REPO_ROOT" diff --quiet HEAD -- "$CHECK_FILE"; then
  echo "ERROR: $CHECK_FILE has uncommitted changes." >&2
  echo "       Commit it first, then re-run this script." >&2
  exit 1
fi

# Compute compose_hash = sha256(canonical-json(app_compose))
COMPOSE_HASH="0x$(
python3 <<PY
import hashlib, json, pathlib, yaml, sys
app_compose_path = "$APP_COMPOSE_FILE"
compose_yaml_path = "$COMPOSE_FILE"

if app_compose_path:
    app_compose = json.loads(pathlib.Path(app_compose_path).read_text())
else:
    # Synthesize a minimal app-compose.json wrapping the docker-compose.yaml.
    # This is what dstack would generate with `phala deploy` — we reproduce
    # the deterministic shape here so our on-chain hash matches theirs.
    docker_yaml = pathlib.Path(compose_yaml_path).read_text()
    app_compose = {
        "manifest_version": 2,
        "name": "feedling-mcp-v1",
        "runner": "docker-compose",
        "docker_compose_file": docker_yaml,
        "docker_config": {},
        "kms_enabled": True,
        "tproxy_enabled": True,
        "public_logs": False,
        "public_sysinfo": False,
        "public_tcbinfo": False,
        "local_key_provider_enabled": False,
        "allowed_envs": [],
        "no_instance_id": False,
    }

canonical = json.dumps(app_compose, separators=(",", ":"), sort_keys=True)
print(hashlib.sha256(canonical.encode()).hexdigest())
PY
)"

GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
REMOTE_URL="$(git -C "$REPO_ROOT" config --get remote.origin.url | \
  sed -e 's|\.git$||' -e 's|git@github.com:|https://github.com/|')"
REL_COMPOSE="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$COMPOSE_FILE" "$REPO_ROOT")"
YAML_URL="${REMOTE_URL}/raw/${GIT_COMMIT}/${REL_COMPOSE}"

echo ">>> compose_file  : $COMPOSE_FILE"
echo ">>> app_compose   : ${APP_COMPOSE_FILE:-(synthesized from docker-compose.yaml)}"
echo ">>> compose_hash  : $COMPOSE_HASH"
echo ">>> git_commit    : $GIT_COMMIT"
echo ">>> yaml_url      : $YAML_URL"
echo ">>> chain         : $CHAIN"
echo

cd "$REPO_ROOT/contracts"
make add-hash CHAIN="$CHAIN" \
  COMPOSE_HASH="$COMPOSE_HASH" \
  COMMIT="$GIT_COMMIT" \
  YAML_URL="$YAML_URL"
