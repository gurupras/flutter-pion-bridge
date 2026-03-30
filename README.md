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

### 3. Build the native bindings (required before every Flutter build)

```bash
./scripts/build_android.sh
```

This runs `gomobile bind` and unpacks the result into:
- `android/libs/pionbridge-go.jar` — Java bindings
- `android/src/main/jniLibs/<ABI>/libgojni.so` — native libs for arm64-v8a, armeabi-v7a, x86_64

Re-run whenever Go source files change. The Flutter build does **not** run this automatically.

### 4. Build the APK

```bash
cd example

# Debug APK (for development / flutter run)
flutter build apk --debug

# Release APK
flutter build apk --release

# Or just run directly on a connected device (builds debug APK implicitly)
flutter run
```

The APK is output to `example/build/app/outputs/flutter-apk/`.

To verify the native library was packaged correctly:
```bash
./scripts/check_apk.sh
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

## Backpressure Handling

When sending large amounts of data over a DataChannel, the native send buffer can fill up faster than the remote peer can receive. To avoid dropping packets or blocking the sender, use the buffered amount low threshold to implement flow control:

```dart
// After the DataChannel opens:
await dataChannel.setBufferedAmountLowThreshold(8192); // 8 KB threshold

// Listen for the low water mark event
dataChannel.onBufferedAmountLow.listen((_) {
  // Buffer has drained below 8 KB; safe to send more data
  sendMoreData();
});

// When sending large amounts, check backpressure:
Future<void> sendData(List<int> payload) async {
  // Only call send() if we know the buffer isn't too full
  // The onBufferedAmountLow event will signal when space is available
  await dataChannel.sendBinary(payload);
}
```

**How it works:**
1. Set a low threshold (e.g., 8-16 KB) after the channel opens
2. Send data as normal — the send buffer will fill up if the remote peer is slow
3. When the buffer drains below your threshold, `onBufferedAmountLow` fires
4. Pause sending until the event fires again

**Best practices:**
- Set threshold to a small value relative to your typical message size
- Higher threshold = more latency before flow control kicks in; lower threshold = more events
- For most uses, 8-16 KB is reasonable
- For bulk transfers, implement an event-driven queue that only sends when `onBufferedAmountLow` fires

The threshold is per-channel, so multiple channels can have independent backpressure policies.

## Example app

The `example/` directory contains a multi-tab demo that:

- **Local peer tab**: Creates a loopback connection, demonstrates single-PC operations
- **Remote peer tab**: Shows how to drive a peer connection from a different context (simulating real signaling)
- Validates DataChannel message ordering and backpressure handling

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
