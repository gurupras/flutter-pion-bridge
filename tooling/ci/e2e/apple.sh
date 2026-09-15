#!/usr/bin/env bash
# e2e test on macOS desktop (both bridge modes) and an iOS simulator, against
# dist/. Runs inside the macos-golden Tart VM, which ships a pre-booted
# "ci-iphone" simulator (created here if missing).
#
# Usage: apple.sh [macos] [ios]   (default: both)
set -euo pipefail

export PATH="/usr/local/go/bin:$HOME/go/bin:$HOME/flutter/bin:/opt/homebrew/bin:$PATH"
export LANG=en_US.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
platforms=("$@")
[[ ${#platforms[@]} -gt 0 ]] || platforms=(macos ios)

bash "$REPO_ROOT/tooling/ci/e2e/prepare.sh" "${platforms[@]}"
export PION_BRIDGE_BINARIES_BASE_URL="file://$REPO_ROOT/dist"
cd "$REPO_ROOT/example"

for platform in "${platforms[@]}"; do
  case "$platform" in
    macos)
      echo "=== e2e: macOS ==="
      flutter test -d macos integration_test/e2e_test.dart
      ;;
    ios)
      echo "=== e2e: iOS simulator ==="
      # Parse captured output: an early-exiting reader in a pipeline would
      # SIGPIPE simctl and fail the script under pipefail.
      devices="$(xcrun simctl list devices available)"
      udid="$(awk -F'[()]' '/^ *ci-iphone \(/ {print $2; exit}' <<< "$devices")"
      if [[ -z "$udid" ]]; then
        runtimes="$(xcrun simctl list runtimes)"
        runtime="$(awk '/^iOS/ {print $NF; exit}' <<< "$runtimes")"
        udid="$(xcrun simctl create ci-iphone com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")"
      fi
      xcrun simctl bootstatus "$udid" -b > /dev/null
      flutter test -d "$udid" integration_test/e2e_test.dart
      ;;
    *)
      echo "Unknown platform '$platform'. Use macos or ios." >&2
      exit 1
      ;;
  esac
done
