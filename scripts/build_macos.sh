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

# Shared mode: the same server as an in-process library (dart:ffi). Needs cgo, so
# each arch is compiled with clang targeting that arch, then lipo'd.
LIB_DIR="$REPO_ROOT/macos/Libraries"
mkdir -p "$LIB_DIR"
for arch in amd64 arm64; do
  carch=$([[ $arch == amd64 ]] && echo x86_64 || echo arm64)
  echo "Building shared library darwin/$arch …"
  # Match Flutter's macOS deployment target, or the app links a dylib "built for
  # newer macOS" than it targets.
  env CGO_ENABLED=1 GOOS=darwin GOARCH=$arch CC="clang -arch $carch" \
      CGO_CFLAGS="-mmacosx-version-min=10.15" \
      CGO_LDFLAGS="-mmacosx-version-min=10.15 -Wl,-install_name,@rpath/libpionbridge.dylib" \
      go build -C "$GO_DIR" -buildmode=c-shared -o "$TMP/libpionbridge_$arch.dylib" ./shared
done
lipo -create -output "$LIB_DIR/libpionbridge.dylib" \
    "$TMP/libpionbridge_amd64.dylib" "$TMP/libpionbridge_arm64.dylib"
echo "  → $LIB_DIR/libpionbridge.dylib"
echo "macOS build complete."
