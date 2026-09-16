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
# command would otherwise sit until the Jenkins stage timeout.
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
    wait "$pid" 2> /dev/null || true
    return 124
  fi
  wait "$pid"
}

# `flutter test` on a simulator reports its results and then does not exit
# here — build #7 printed "All tests passed!" and was still running 3 minutes
# later. Follow the output and stop as soon as it reports, instead of waiting
# for a process that never returns.
run_ios_test() {
  local udid="$1" log="$2" waited=0 pid rc
  : > "$log"
  flutter test -d "$udid" integration_test/e2e_test.dart > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2> /dev/null; do
    if grep -q 'All tests passed!' "$log"; then
      kill -9 "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
      cat "$log"
      return 0
    fi
    if grep -q 'Some tests failed' "$log"; then
      kill -9 "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
      cat "$log"
      return 1
    fi
    if [ "$waited" -ge 900 ]; then
      echo "iOS test produced no result after ${waited}s" >&2
      kill -9 "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
      cat "$log"
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done
  rc=0
  wait "$pid" || rc=$?
  cat "$log"
  grep -q 'All tests passed!' "$log" && return 0
  return "$rc"
}

# The device does not stay up on its own here: it was Booted when the run
# started and Shutdown ten minutes later when flutter tried to install, which
# fails with "Unable to lookup in current state: Shutdown". Re-boot it for as
# long as the test runs.
keep_simulator_booted() {
  local udid="$1"
  while :; do
    if [ "$(simulator_state "$udid")" != Booted ]; then
      xcrun simctl boot "$udid" 2> /dev/null || true
    fi
    sleep 15
  done
}

simulator_state() {
  xcrun simctl list devices | sed -nE "s/.*$1\) \((.*)\).*/\1/p"
}

boot_simulator() {
  local udid="$1" waited=0 state
  xcrun simctl boot "$udid" 2> /dev/null || true
  while :; do
    state="$(simulator_state "$udid")"
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
      # Build before the simulator is running: attempts that compiled while the
      # device was up stalled every time on this 8 GB host (#6-#8), and the
      # retry only passed because the build was already cached. The test then
      # just installs and runs.
      run_bounded 1800 flutter build ios --simulator --debug
      boot_simulator "$udid"
      keep_simulator_booted "$udid" &
      keeper=$!
      status=0
      run_ios_test "$udid" "$REPO_ROOT/example/ios-e2e.log" || status=$?
      if [ "$status" -ne 0 ]; then
        echo "iOS run failed or stalled (exit $status); retrying once" >&2
        xcrun simctl shutdown "$udid" 2> /dev/null || true
        boot_simulator "$udid"
        status=0
        run_ios_test "$udid" "$REPO_ROOT/example/ios-e2e.log" || status=$?
      fi
      kill "$keeper" 2> /dev/null || true
      [ "$status" -eq 0 ] || exit "$status"
      ;;
    *)
      echo "Unknown platform '$platform'. Use macos or ios." >&2
      exit 1
      ;;
  esac
done
