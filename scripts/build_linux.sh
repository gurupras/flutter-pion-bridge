#!/usr/bin/env bash
# Build the Go server for Linux, in both deployment modes:
#   sidecar: linux/bundle/lib/pionbridge        (spawned process, WebSocket)
#   shared:  linux/bundle/lib/libpionbridge.so  (loaded in-process via dart:ffi)
# Both are bundled next to the app. The shared library needs cgo, so a
# non-native arch is built only when CC_<arch> names a cross compiler
# (e.g. CC_arm64=aarch64-linux-gnu-gcc).
#
# Usage: ./build_linux.sh [amd64|arm64|all]  (default: amd64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_DIR="$REPO_ROOT/go"

ARCH="${1:-amd64}"

build_arch() {
  local goarch="$1"
  local out_dir="$REPO_ROOT/linux/bundle/lib"
  mkdir -p "$out_dir"
  local out="$out_dir/pionbridge"
  [[ "$goarch" != "amd64" ]] && out="${out}_${goarch}"

  echo "Building linux/$goarch …"
  env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
      go build -C "$GO_DIR" -o "$out" .
  echo "  → $out"

  local lib="$out_dir/libpionbridge.so"
  [[ "$goarch" != "amd64" ]] && lib="$out_dir/libpionbridge_${goarch}.so"
  local cc_var="CC_${goarch}"
  local cc="${!cc_var:-}"
  if [[ -z "$cc" && "$goarch" != "$(go env GOHOSTARCH)" ]]; then
    echo "  (skipping shared library for $goarch: set $cc_var to a cross compiler)"
    return
  fi
  env CGO_ENABLED=1 GOOS=linux GOARCH="$goarch" ${cc:+CC="$cc"} \
      go build -C "$GO_DIR" -buildmode=c-shared -o "$lib" ./shared
  rm -f "${lib%.so}.h"
  echo "  → $lib"
}

case "$ARCH" in
  all)
    build_arch amd64
    build_arch arm64
    ;;
  amd64|arm64)
    build_arch "$ARCH"
    ;;
  *)
    echo "Unknown arch '$ARCH'. Use amd64, arm64, or all." >&2
    exit 1
    ;;
esac

echo "Linux build complete."
