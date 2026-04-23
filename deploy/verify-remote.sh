#!/usr/bin/env bash
# verify-remote.sh — rebuild Feedling's backend image on a remote machine
# and compare against the sha256 in deploy/build-manifest.json.
#
# Shape adapted from dstack-tutorial/02-bitrot-and-reproducibility. A
# successful run proves the build is deterministic across machines —
# i.e. that the compose_hash advertised on-chain corresponds to a
# recipe any auditor can reproduce.
#
# Usage:
#     ./deploy/verify-remote.sh user@host [expected-hash]
# If no expected hash is given, deploy/build-manifest.json is read.

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

if [[ $# -lt 1 ]]; then
    echo "usage: $0 user@host [expected-hash]" >&2
    exit 1
fi
REMOTE="$1"

if [[ $# -ge 2 ]]; then
    EXPECTED="$2"
elif [[ -f deploy/build-manifest.json ]]; then
    EXPECTED=$(jq -r .image_hash deploy/build-manifest.json)
else
    echo "no expected hash provided and deploy/build-manifest.json missing." >&2
    echo "run deploy/build-reproducible.sh first, or pass the hash explicitly." >&2
    exit 1
fi

echo "=== Feedling Remote Reproducibility Test ==="
echo "Remote:   $REMOTE"
echo "Expected: ${EXPECTED:0:16}..."

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Only the bits that affect the image: Dockerfile + backend tree +
# requirements.lock. Nothing host-specific.
tar --exclude='__pycache__' --exclude='*.pyc' --exclude='.venv' \
    -czf "$TMPDIR/feedling-verify-src.tar.gz" \
    deploy/Dockerfile \
    backend/

echo "Copying source tarball to $REMOTE..."
scp -q "$TMPDIR/feedling-verify-src.tar.gz" "$REMOTE:/tmp/feedling-verify-src.tar.gz"

echo "Building on remote..."
REMOTE_HASH=$(ssh -q "$REMOTE" bash -s << 'ENDSSH'
set -euo pipefail
workdir=$(mktemp -d)
trap "rm -rf $workdir /tmp/feedling-verify-src.tar.gz" EXIT
cd "$workdir"
tar -xzf /tmp/feedling-verify-src.tar.gz

docker buildx create --name feedling-repro-verify --driver docker-container >/dev/null 2>&1 || true

docker buildx build \
    --builder feedling-repro-verify \
    --build-arg SOURCE_DATE_EPOCH=0 \
    --build-arg FEEDLING_GIT_COMMIT=dev \
    --build-arg FEEDLING_BUILT_AT=dev \
    --build-arg FEEDLING_IMAGE_DIGEST=sha256:dev \
    --no-cache \
    -f deploy/Dockerfile \
    --output type=oci,dest=verify.tar,rewrite-timestamp=true \
    . >/dev/null 2>&1

sha256sum verify.tar | awk '{print $1}'
ENDSSH
)

echo
echo "=== Results ==="
echo "Expected: $EXPECTED"
echo "Remote:   $REMOTE_HASH"
echo

if [[ "$EXPECTED" == "$REMOTE_HASH" ]]; then
    echo "VERIFIED — remote build matches local manifest."
    exit 0
else
    echo "MISMATCH — remote build differs."
    echo "Likely causes: dockerfile/backend tree out of sync, Docker Buildx"
    echo "version drift, or apt package-set drift on the base image."
    exit 1
fi
