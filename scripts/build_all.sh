#!/usr/bin/env bash
# Build Go server binaries for all supported platforms.
# Skips Android if ANDROID_NDK_HOME is not set.
# Skips macOS lipo step if not on macOS (builds individual arches instead).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Linux ==="
bash "$SCRIPT_DIR/build_linux.sh" all

echo ""
echo "=== Windows ==="
bash "$SCRIPT_DIR/build_windows.sh"

echo ""
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "=== macOS ==="
  bash "$SCRIPT_DIR/build_macos.sh"
else
  echo "=== macOS (skipped — not running on macOS) ==="
fi

echo ""
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  echo "=== Android ==="
  bash "$SCRIPT_DIR/build_android.sh"
else
  echo "=== Android (skipped — ANDROID_NDK_HOME not set) ==="
fi

echo ""
if [[ "$(uname -s)" == "Darwin" ]] && command -v gomobile &>/dev/null; then
  echo "=== iOS ==="
  bash "$SCRIPT_DIR/build_ios.sh"
else
  echo "=== iOS (skipped — requires macOS and gomobile) ==="
fi

echo ""
echo "All builds complete."
