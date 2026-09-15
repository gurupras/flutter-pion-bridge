#!/usr/bin/env bash
# Build and package the macOS and iOS release archives into dist/. Runs inside
# the disposable macos-golden Tart VM (macosBuildVM), which ships Go and Xcode
# but nothing on the non-interactive PATH.
set -euo pipefail

export PATH="/usr/local/go/bin:$HOME/go/bin:/opt/homebrew/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

go version
xcodebuild -version

bash tooling/ci/install_gomobile.sh
bash scripts/build_macos.sh
bash scripts/build_ios.sh
bash scripts/package_release.sh macos ios
