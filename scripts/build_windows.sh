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
echo "Windows build complete."
