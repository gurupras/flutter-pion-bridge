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

# Wait for the device to reach Booted, and no further. `simctl bootstatus`
# waits for a full boot that never completes in these VMs — SpringBoard does
# not come up and it hangs for as long as the stage allows — while installing
# and launching an app on the Booted device works fine, which is all the test
# needs. (`simctl spawn` is not a readiness signal: it succeeds on a shut-down
# device.)
# run_bounded <seconds> <command>... — macOS has no timeout(1), and a stalled
# `flutter test` would otherwise sit until the Jenkins stage timeout.
run_bounded() {
  local limit="$1" pid waited=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2> /dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 10
    waited=$((waited + 10))
  done
  if kill -0 "$pid" 2> /dev/null; then
    echo "'$*' still running after ${waited}s; killing it" >&2
    kill -9 "$pid" 2> /dev/null || true
    pkill -f 'flutter_tools.snapshot test' 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    return 124
  fi
  wait "$pid"
}

boot_simulator() {
  local udid="$1" waited=0 state
  xcrun simctl boot "$udid" 2> /dev/null || true
  while :; do
    state="$(xcrun simctl list devices | sed -nE "s/.*$udid\) \((.*)\).*/\1/p")"
    [ "$state" = Booted ] && break
    if [ "$waited" -ge 300 ]; then
      echo "simulator $udid stuck in state '$state' after ${waited}s" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "simulator booted after ${waited}s"
}

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
      # CoreSimulator wedges under memory pressure on this host (8 GB shared
      # with a 4 GB VM): simctl calls stop returning and `flutter test` waits
      # forever on an app that never launches, so the run is bounded. Erasing
      # the device clears the wedge.
      boot_simulator "$udid"
      if ! run_bounded 900 flutter test -d "$udid" integration_test/e2e_test.dart; then
        echo "iOS run failed or stalled; erasing the simulator and retrying once" >&2
        xcrun simctl shutdown "$udid" 2> /dev/null || true
        xcrun simctl erase "$udid"
        boot_simulator "$udid"
        run_bounded 900 flutter test -d "$udid" integration_test/e2e_test.dart
      fi
      ;;
    *)
      echo "Unknown platform '$platform'. Use macos or ios." >&2
      exit 1
      ;;
  esac
done
