#!/usr/bin/env bash
# Build the PionBridge Android bindings via gomobile bind, then unpack the AAR
# so it can be consumed by the plugin library module without AAR-in-AAR issues.
#
# Outputs:
#   android/libs/pionbridge-go.jar        (Java bindings)
#   android/src/main/jniLibs/<ABI>/*.so   (native libs)
#
# Requirements:
#   - Go toolchain
#   - gomobile: go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
#   - ANDROID_HOME  (default: ~/android-sdk-linux)
#   - ANDROID_NDK_HOME  (default: ANDROID_HOME/ndk/28.2.13676358)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk-linux}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}"

LIBS_DIR="$REPO_ROOT/android/libs"
JNI_DIR="$REPO_ROOT/android/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
AAR="$WORK_DIR/pionbridge.aar"

mkdir -p "$LIBS_DIR"

if ! command -v gomobile &>/dev/null; then
  echo "ERROR: gomobile not found. Run:" >&2
  echo "  go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init" >&2
  exit 1
fi

echo "Building Android AAR via gomobile bind…"
cd "$REPO_ROOT/go"
gomobile bind \
  -target android \
  -androidapi 21 \
  -ldflags="-checklinkname=0" \
  -o "$AAR" \
  ./mobile/

echo "Unpacking AAR…"

# Extract classes.jar → android/libs/pionbridge-go.jar
unzip -p "$AAR" classes.jar > "$LIBS_DIR/pionbridge-go.jar"
echo "  → android/libs/pionbridge-go.jar"

# Extract native libs → android/src/main/jniLibs/<ABI>/
for ABI in arm64-v8a armeabi-v7a x86_64; do
  SO_PATH="jni/$ABI/libgojni.so"
  if unzip -l "$AAR" | grep -q "$SO_PATH"; then
    mkdir -p "$JNI_DIR/$ABI"
    unzip -p "$AAR" "$SO_PATH" > "$JNI_DIR/$ABI/libgojni.so"
    echo "  → android/src/main/jniLibs/$ABI/libgojni.so"
  fi
done

rm -rf "$WORK_DIR"
echo "Android build complete."
