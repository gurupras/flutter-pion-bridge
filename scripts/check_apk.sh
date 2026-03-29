#!/usr/bin/env bash
# Check whether libpionbridge.so is packaged inside the APK.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="${1:-$SCRIPT_DIR/../example/build/app/outputs/flutter-apk/app-debug.apk}"

flutter build apk

if [[ ! -f "$APK" ]]; then
  echo "APK not found at: $APK"
  echo "Usage: $0 [path/to/app.apk]"
  exit 1
fi

echo "Scanning: $APK"
echo ""

FOUND=$(unzip -l "$APK" | grep "libpionbridge.so" || true)

if [[ -z "$FOUND" ]]; then
  echo "NOT FOUND — libpionbridge.so is not in the APK."
  echo ""
  echo "All lib/ entries:"
  unzip -l "$APK" | grep "lib/" || echo "  (none)"
else
  echo "FOUND:"
  echo "$FOUND"
fi
