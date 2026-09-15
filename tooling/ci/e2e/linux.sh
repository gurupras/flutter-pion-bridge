#!/usr/bin/env bash
# e2e test on Linux desktop (both bridge modes) under Xvfb, against dist/.
# Runs in the Linux builder image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bash "$REPO_ROOT/tooling/ci/e2e/prepare.sh" linux
export PION_BRIDGE_BINARIES_BASE_URL="file://$REPO_ROOT/dist"

cd "$REPO_ROOT/example"
xvfb-run -a flutter test -d linux integration_test/e2e_test.dart
