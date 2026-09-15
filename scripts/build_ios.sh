#!/usr/bin/env bash
# Build the Go server as an iOS xcframework via gomobile bind.
# Output: ios/Frameworks/PionBridgeGo.xcframework
#
# Requirements:
#   - Go toolchain installed
#   - gomobile installed: go install golang.org/x/mobile/cmd/gomobile@latest
#   - gomobile init run at least once: gomobile init
#   - Xcode command-line tools installed (macOS only)
#
# Must be run on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_DIR="$REPO_ROOT/go"
OUT_DIR="$REPO_ROOT/ios/Frameworks"
mkdir -p "$OUT_DIR"

# Verify gomobile is available
if ! command -v gomobile &>/dev/null; then
  echo "ERROR: gomobile not found. Install with:" >&2
  echo "  go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init" >&2
  exit 1
fi

echo "Building iOS xcframework via gomobile bind …"
# xcodebuild -create-xcframework refuses to overwrite: without this, a second
# build in the same tree fails with "an item with the same name already exists".
rm -rf "$OUT_DIR/PionBridgeGo.xcframework"
cd "$GO_DIR"
gomobile bind \
  -target ios \
  -ldflags="-checklinkname=0" \
  -o "$OUT_DIR/PionBridgeGo.xcframework" \
  ./mobile/

echo "  → $OUT_DIR/PionBridgeGo.xcframework"
echo "iOS build complete."
