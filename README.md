# flutter-pion-bridge

A Flutter plugin that embeds a [Pion](https://github.com/pion/webrtc) WebRTC server in-process via [gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile), exposing peer connections and data channels to Dart.

## Architecture

```
Dart (Flutter)
    │  WebSocket (localhost)
    ▼
Go (gomobile, in-process)
    │  pion/webrtc
    ▼
WebRTC DataChannel / ICE / DTLS
```

The Go server runs inside the app process (via gomobile bind). Dart communicates with it over a local WebSocket using a msgpack protocol. From Dart's perspective it's a simple async API — no subprocesses, no native FFI.

## Requirements

| Tool | Version |
|------|---------|
| Go | 1.25+ |
| gomobile | latest (`golang.org/x/mobile`) |
| Flutter | 3.10+ |
| Android NDK | 28.2+ |
| Xcode (iOS only) | 15+ (macOS only) |

## Building for Android

### 1. Prerequisites

```bash
# Install Go 1.25+
# https://go.dev/dl/

# Install gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# Run gomobile init from inside the go/ module
cd go && gomobile init && cd ..
```

### 2. Set environment variables

```bash
export ANDROID_HOME=~/android-sdk-linux        # or wherever your SDK is
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358
```

### 3. Build the native bindings

```bash
./scripts/build_android.sh
```

This produces:
- `android/libs/pionbridge-go.jar` — Java bindings
- `android/src/main/jniLibs/<ABI>/libgojni.so` — native libraries for arm64-v8a, armeabi-v7a, x86_64

Re-run this script whenever Go source files change.

### 4. Run the example app

```bash
cd example && flutter run
```

## Building for iOS

> iOS builds must be run on macOS.

### 1. Prerequisites

```bash
# Install Xcode and command-line tools
xcode-select --install

# Install Go 1.25+
# https://go.dev/dl/

# Install gomobile
go install golang.org/x/mobile/cmd/gomobile@latest
cd go && gomobile init && cd ..
```

### 2. Build the xcframework

```bash
./scripts/build_ios.sh
```

This produces `ios/Frameworks/PionBridgeGo.xcframework`.

Re-run this script whenever Go source files change.

### 3. Run the example app

```bash
cd example && flutter run
```

CocoaPods will pick up the xcframework automatically via the podspec.

## Hot restart

Hot restart reinitialises the Dart layer and calls `startServer` again. The plugin handles this by stopping any running server before starting a new one — hot restart works without manual intervention.

## Example app

The `example/` directory contains a throughput test that:

- Creates two loopback peer connections on the same device
- Sends binary data over one or more DataChannels
- Measures throughput (MB/s), reports per-DC distribution, and validates chunk ordering via sequence numbers

## Project structure

```
android/          Kotlin plugin (calls Mobile.start/stop via gomobile AAR)
ios/              Swift plugin (calls PionBridgeGo.xcframework)
go/
  main.go         Standalone binary entry point (unused on mobile)
  mobile/         gomobile bind entry point (Start/Stop)
  internal/
    pionserver/   WebSocket server, pion WebRTC handler, registry
lib/              Dart API (PionBridge, PionPeerConnection, PionDataChannel)
scripts/
  build_android.sh   Builds gomobile AAR and unpacks it
  build_ios.sh       Builds gomobile xcframework
  check_apk.sh       Verifies libgojni.so is packaged in the APK
example/          Flutter throughput test app
```

## Known limitations

- Multiple DataChannels on one PeerConnection share the same SCTP association — they do not increase raw bandwidth, only provide head-of-line blocking isolation.
- SELinux `netlink_route_socket` denials appear in Android logs from pion's network interface enumeration. These are harmless warnings; pion falls back gracefully.
