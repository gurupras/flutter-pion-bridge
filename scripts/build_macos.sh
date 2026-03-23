#!/usr/bin/env bash
# Build the Go server binary for macOS.
# Produces a universal binary (amd64 + arm64) via lipo.
# Output: macos/Resources/pionbridge
#
# Requirements: Go toolchain, lipo (ships with Xcode command-line tools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_DIR="$REPO_ROOT/go"
OUT_DIR="$REPO_ROOT/macos/Resources"
mkdir -p "$OUT_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Building darwin/amd64 …"
env CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 \
    go build -C "$GO_DIR" -o "$TMP/pionbridge_amd64" .

echo "Building darwin/arm64 …"
env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    go build -C "$GO_DIR" -o "$TMP/pionbridge_arm64" .

echo "Creating universal binary …"
lipo -create -output "$OUT_DIR/pionbridge" \
    "$TMP/pionbridge_amd64" \
    "$TMP/pionbridge_arm64"
chmod +x "$OUT_DIR/pionbridge"

echo "  → $OUT_DIR/pionbridge"
echo "macOS build complete."
