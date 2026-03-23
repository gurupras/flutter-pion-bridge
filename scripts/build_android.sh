#!/usr/bin/env bash
# Build the Go server binary for Android.
# Outputs libpionbridge.so for each ABI into android/src/main/jniLibs/<ABI>/.
#
# Requirements:
#   - ANDROID_NDK_HOME must be set (or passed as first arg)
#   - Go toolchain installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_DIR="$REPO_ROOT/go"
OUT_BASE="$REPO_ROOT/android/src/main/jniLibs"

NDK="${1:-${ANDROID_NDK_HOME:-}}"
if [[ -z "$NDK" ]]; then
  echo "ERROR: Set ANDROID_NDK_HOME or pass NDK path as first argument." >&2
  exit 1
fi

# Detect host tag (linux-x86_64 / darwin-x86_64 / etc.)
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  HOST_TAG="linux-x86_64" ;;
  Darwin-x86_64) HOST_TAG="darwin-x86_64" ;;
  Darwin-arm64)  HOST_TAG="darwin-x86_64" ;;  # NDK ships x86_64 tools on Apple Silicon too
  *) echo "Unsupported host for Android cross-compile: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
API=21  # min SDK

declare -A ABIS=(
  ["arm64-v8a"]="aarch64-linux-android${API}-clang aarch64 arm64 "
  ["armeabi-v7a"]="armv7a-linux-androideabi${API}-clang arm arm 7"
  ["x86_64"]="x86_64-linux-android${API}-clang amd64 amd64 "
)

for ABI in "${!ABIS[@]}"; do
  read -r CC GOARCH GOARCH2 GOARM <<< "${ABIS[$ABI]}"
  OUT_DIR="$OUT_BASE/$ABI"
  mkdir -p "$OUT_DIR"

  echo "Building $ABI …"
  env CGO_ENABLED=0 \
      GOOS=android \
      GOARCH="$GOARCH" \
      ${GOARM:+GOARM=$GOARM} \
      go build -C "$GO_DIR" -o "$OUT_DIR/libpionbridge.so" .

  echo "  → $OUT_DIR/libpionbridge.so"
done

echo "Android build complete."
