#!/usr/bin/env bash
# Build the Go server binary for Linux.
# Outputs pionbridge to linux/bundle/lib/pionbridge (bundled next to the app).
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
