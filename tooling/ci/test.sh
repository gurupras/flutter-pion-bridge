#!/usr/bin/env bash
# Host test layers (CLAUDE.md "Testing" 1-3), run in the Linux builder image.
# The on-device layer stays manual.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=== Go server ==="
(cd "$REPO_ROOT/go" && go test ./internal/pionserver/ -count=1)
echo "=== Go server (race) ==="
(cd "$REPO_ROOT/go" && go test ./internal/pionserver/ -race -count=1)

echo "=== Vendored pion/sctp fork ==="
(cd "$REPO_ROOT/go/pion-sctp-patched" && go test . -count=1)

echo "=== Dart unit + integration ==="
cd "$REPO_ROOT"
flutter pub get
flutter test test/unit/ test/integration/
