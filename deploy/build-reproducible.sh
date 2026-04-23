#!/usr/bin/env bash
# build-reproducible.sh — build Feedling's backend image deterministically
# and check that two back-to-back builds produce byte-identical output.
#
# Shape matches dstack-tutorial/02-bitrot-and-reproducibility. On success
# writes `deploy/build-manifest.json` with the OCI tarball sha256 +
# image digest. Commit that file alongside a deploy to let third-party
# auditors cross-check.
#
# Usage:   ./deploy/build-reproducible.sh [--skip-second-pass]
# Output:  deploy/build-manifest.json

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

for cmd in docker skopeo jq sha256sum; do
    command -v "$cmd" >/dev/null || { echo "missing command: $cmd" >&2; exit 1; }
done

SKIP_SECOND=${1:-}
BUILDER=feedling-repro-builder
OUT1=deploy/.build1.tar
OUT2=deploy/.build2.tar

if ! docker buildx inspect "$BUILDER" &>/dev/null; then
    docker buildx create --name "$BUILDER" --driver docker-container
fi

build_once() {
    local dest="$1"
    docker buildx build \
        --builder "$BUILDER" \
        --build-arg SOURCE_DATE_EPOCH=0 \
        --build-arg FEEDLING_GIT_COMMIT=dev \
        --build-arg FEEDLING_BUILT_AT=dev \
        --build-arg FEEDLING_IMAGE_DIGEST=sha256:dev \
        --no-cache \
        -f deploy/Dockerfile \
        --output type=oci,dest="$dest",rewrite-timestamp=true \
        .
}

echo "=== Build 1 ==="
build_once "$OUT1"
HASH1=$(sha256sum "$OUT1" | awk '{print $1}')
echo "sha256($OUT1) = $HASH1"

if [[ "$SKIP_SECOND" != "--skip-second-pass" ]]; then
    echo
    echo "=== Build 2 (reproducibility check) ==="
    build_once "$OUT2"
    HASH2=$(sha256sum "$OUT2" | awk '{print $1}')
    echo "sha256($OUT2) = $HASH2"

    if [[ "$HASH1" != "$HASH2" ]]; then
        echo
        echo "NOT REPRODUCIBLE — builds differ."
        echo "Keeping $OUT1 and $OUT2 for inspection:"
        echo "  diff <(tar -tvf $OUT1) <(tar -tvf $OUT2)"
        exit 1
    fi
    rm -f "$OUT2"
fi

DIGEST=$(skopeo inspect "oci-archive:$OUT1" | jq -r .Digest)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > deploy/build-manifest.json <<EOF
{
  "image_hash": "$HASH1",
  "image_digest": "$DIGEST",
  "build_date": "$BUILD_DATE",
  "source_date_epoch": 0,
  "notes": "OCI tarball sha256; image_digest is the content-addressed digest of the OCI image manifest inside the tarball. Re-run build-reproducible.sh on a clean checkout of the same commit to verify."
}
EOF

rm -f "$OUT1"
echo
echo "REPRODUCIBLE"
echo "wrote deploy/build-manifest.json:"
cat deploy/build-manifest.json
