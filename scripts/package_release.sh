#!/usr/bin/env bash
# Package locally built native binaries into per-platform release archives.
#
# Usage: ./package_release.sh <platform>...
#   platforms: android ios macos linux-x64 linux-arm64 windows-x64
#
# Output: dist/pionbridge-<version>-<platform>.tar.gz, <version> from pubspec.yaml.
# Run the matching scripts/build_<platform>.sh first; a missing file is an error,
# so a release never ships an archive without (say) the shared-mode library.
#
# Archive layouts are what build_support/ extracts at app build time — change
# both together:
#   android      pionbridge-go.jar  jniLibs/<abi>/libgojni.so
#   ios          PionBridgeGo.xcframework/
#   macos        pionbridge  libpionbridge.dylib
#   linux-*      pionbridge  libpionbridge.so
#   windows-x64  pionbridge.exe  pionbridge.dll

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="$(sed -nE '/^version:/{s/^version:[[:space:]]*([^+[:space:]]+).*/\1/p;q;}' "$REPO_ROOT/pubspec.yaml")"
[[ -n "$VERSION" ]] || { echo "ERROR: no version in pubspec.yaml" >&2; exit 1; }

DIST="$REPO_ROOT/dist"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# stage <platform> <source> <name-in-archive>
stage() {
  local src="$REPO_ROOT/$2"
  if [[ ! -e "$src" ]]; then
    echo "ERROR: $2 not found — build $1 first" >&2
    exit 1
  fi
  mkdir -p "$STAGE/$1/$(dirname "$3")"
  cp -R "$src" "$STAGE/$1/$3"
}

for platform in "$@"; do
  case "$platform" in
    android)
      stage android android/libs/pionbridge-go.jar pionbridge-go.jar
      for abi in arm64-v8a armeabi-v7a x86_64; do
        stage android "android/src/main/jniLibs/$abi/libgojni.so" "jniLibs/$abi/libgojni.so"
      done
      ;;
    ios)
      stage ios ios/Frameworks/PionBridgeGo.xcframework PionBridgeGo.xcframework
      ;;
    macos)
      stage macos macos/Resources/pionbridge pionbridge
      stage macos macos/Libraries/libpionbridge.dylib libpionbridge.dylib
      ;;
    linux-x64)
      stage linux-x64 linux/bundle/lib/pionbridge pionbridge
      stage linux-x64 linux/bundle/lib/libpionbridge.so libpionbridge.so
      ;;
    linux-arm64)
      stage linux-arm64 linux/bundle/lib/pionbridge_arm64 pionbridge
      stage linux-arm64 linux/bundle/lib/libpionbridge_arm64.so libpionbridge.so
      ;;
    windows-x64)
      stage windows-x64 windows/runner/resources/pionbridge.exe pionbridge.exe
      stage windows-x64 windows/runner/resources/pionbridge.dll pionbridge.dll
      ;;
    *)
      echo "Unknown platform '$platform'." >&2
      echo "Use: android ios macos linux-x64 linux-arm64 windows-x64" >&2
      exit 1
      ;;
  esac

  out="$DIST/pionbridge-$VERSION-$platform.tar.gz"
  # COPYFILE_DISABLE keeps macOS tar from adding ._ AppleDouble entries.
  (cd "$STAGE/$platform" && COPYFILE_DISABLE=1 tar -czf "$out" .)
  echo "  → dist/$(basename "$out")"
done
