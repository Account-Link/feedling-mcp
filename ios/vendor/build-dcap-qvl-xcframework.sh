#!/usr/bin/env bash
# build-dcap-qvl-xcframework.sh — build Phala-Network/dcap-qvl for iOS
# targets and package the result as an XCFramework at
# ios/vendor/dcap_qvl.xcframework.
#
# Run this once after cloning the repo (or whenever dcap-qvl upstream
# is bumped). The XCFramework is committed to git for convenience so
# fresh clones don't need Rust installed just to build the iOS app.
#
# Prereqs:
#   - rustc >= 1.85 with targets aarch64-apple-ios, aarch64-apple-ios-sim
#   - Xcode with xcodebuild
#
# Output lives at ios/vendor/dcap_qvl.xcframework/.

set -euo pipefail
cd "$(dirname "$0")"   # ios/vendor

CRATE_DIR="dcap-qvl"
INCLUDE_DIR="include"
OUT="dcap_qvl.xcframework"

if [[ ! -d "$CRATE_DIR" ]]; then
    echo "error: expected $CRATE_DIR source tree to exist under ios/vendor/" >&2
    echo "       the repo commits it as a vendored subtree; if yours is missing," >&2
    echo "       clone https://github.com/Phala-Network/dcap-qvl.git into $CRATE_DIR" >&2
    exit 1
fi

for triple in aarch64-apple-ios aarch64-apple-ios-sim; do
    if ! rustup target list --installed | grep -qx "$triple"; then
        echo "installing rustup target $triple"
        rustup target add "$triple"
    fi
done

echo "==> Building dcap-qvl for aarch64-apple-ios"
(cd "$CRATE_DIR" && cargo build --release --target aarch64-apple-ios \
    --no-default-features --features go)

echo "==> Building dcap-qvl for aarch64-apple-ios-sim"
(cd "$CRATE_DIR" && cargo build --release --target aarch64-apple-ios-sim \
    --no-default-features --features go)

echo "==> Packaging XCFramework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$CRATE_DIR/target/aarch64-apple-ios/release/libdcap_qvl.a" -headers "$INCLUDE_DIR" \
    -library "$CRATE_DIR/target/aarch64-apple-ios-sim/release/libdcap_qvl.a" -headers "$INCLUDE_DIR" \
    -output "$OUT"

ls -la "$OUT/"
echo "done — $OUT ready to link in Xcode (see integrate-xcframework.py)."
