#!/usr/bin/env bash
# e2e test on a headless Android emulator, against dist/. Runs in the Linux
# builder image started with --device /dev/kvm.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bash "$REPO_ROOT/tooling/ci/e2e/prepare.sh" android
export PION_BRIDGE_BINARIES_BASE_URL="file://$REPO_ROOT/dist"

echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
  --force --name e2e --package "$ANDROID_SYSTEM_IMAGE" --device pixel_6 > /dev/null
emulator -accel-check

emulator -avd e2e -no-window -no-audio -no-boot-anim -no-snapshot -no-metrics \
  -gpu swiftshader_indirect > "$REPO_ROOT/example/emulator.log" 2>&1 &
EMULATOR_PID=$!
trap 'adb emu kill > /dev/null 2>&1 || true; kill "$EMULATOR_PID" 2> /dev/null || true' EXIT

adb wait-for-device
for _ in $(seq 1 150); do
  [[ "$(adb shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" == 1 ]] && break
  kill -0 "$EMULATOR_PID" 2> /dev/null || { cat "$REPO_ROOT/example/emulator.log"; exit 1; }
  sleep 2
done
[[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || { echo "emulator did not boot" >&2; exit 1; }

cd "$REPO_ROOT/example"
flutter test -d emulator-5554 integration_test/e2e_test.dart
