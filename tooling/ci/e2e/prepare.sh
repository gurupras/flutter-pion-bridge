#!/usr/bin/env bash
# Prepare the example app to run integration_test/e2e_test.dart against the
# release archives in dist/ (from scripts/package_release.sh). Build/run with
# PION_BRIDGE_BINARIES_BASE_URL=file://<repo>/dist, which makes the platform
# builds download those archives even when local build outputs exist.
#
# Usage: prepare.sh <platform>...   (linux android macos ios)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

# Archives are cached per version, not per content: drop earlier extractions
# so this run uses the archives in dist/ (the CMake and Gradle caches live in
# example/build, cleared below).
rm -rf macos/Downloaded ios/Downloaded example/build

cd dist
ls pionbridge-*.tar.gz > /dev/null
if command -v sha256sum > /dev/null; then
  sha256sum pionbridge-*.tar.gz > SHA256SUMS
else
  shasum -a 256 pionbridge-*.tar.gz > SHA256SUMS
fi
cat SHA256SUMS

# The example commits only its Android and Linux runners; generate the rest.
cd "$REPO_ROOT/example"
flutter create --platforms="$(IFS=,; echo "$*")" --org io.filemingo . > /dev/null

# A sandboxed macOS app needs the client entitlement to reach the sidecar on
# 127.0.0.1 — Flutter's template grants only network.server, and without this
# every connect fails with "Operation not permitted". Real apps need the same
# (see README).
if [[ " $* " == *" macos "* ]]; then
  for plist in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.client bool true' "$plist" 2> /dev/null \
      || /usr/libexec/PlistBuddy -c 'Set :com.apple.security.network.client true' "$plist"
  done
fi
