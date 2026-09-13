#!/usr/bin/env bash
# Build the Go server binary for Windows (amd64).
# Can be run on Linux (cross-compile) or on Windows via Git Bash / WSL.
# Output: windows/runner/resources/pionbridge.exe

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_DIR="$REPO_ROOT/go"
OUT_DIR="$REPO_ROOT/windows/runner/resources"
mkdir -p "$OUT_DIR"

echo "Building windows/amd64 …"
env CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
    go build -C "$GO_DIR" -o "$OUT_DIR/pionbridge.exe" .

echo "  → $OUT_DIR/pionbridge.exe"

# Shared mode: the same server as an in-process DLL (dart:ffi). Needs cgo, so a
# MinGW-w64 C compiler is required (native on Windows, or cross from Linux).
CC_WIN="${CC_WINDOWS:-x86_64-w64-mingw32-gcc}"
if command -v "$CC_WIN" >/dev/null 2>&1; then
  echo "Building shared library windows/amd64 …"
  env CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC="$CC_WIN" \
      go build -C "$GO_DIR" -buildmode=c-shared -o "$OUT_DIR/pionbridge.dll" ./shared
  rm -f "$OUT_DIR/pionbridge.h"
  echo "  → $OUT_DIR/pionbridge.dll"
else
  echo "  (skipping pionbridge.dll: no $CC_WIN; set CC_WINDOWS to a MinGW-w64 gcc)"
fi
echo "Windows build complete."
