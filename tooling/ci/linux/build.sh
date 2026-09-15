#!/usr/bin/env bash
# Build and package the Android, Linux (amd64 + arm64) and Windows release
# archives into dist/. Runs in the Linux builder image (tooling/ci/linux/Dockerfile).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

bash tooling/ci/install_gomobile.sh
bash scripts/build_android.sh
CC_arm64=aarch64-linux-gnu-gcc bash scripts/build_linux.sh all
bash scripts/build_windows.sh
bash scripts/package_release.sh android linux-x64 linux-arm64 windows-x64
