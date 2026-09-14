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

## SettingEngine Configuration

`PionBridge.initialize()` accepts an optional `settingsEngine` parameter that lets you tune the underlying pion `SettingEngine` before any peer connections are created. These settings apply globally — all `PionPeerConnection` instances in the session share the same configuration.

```dart
final bridge = await PionBridge.initialize(
  settingsEngine: PionSettingsEngine(
    // Increase SCTP receive buffer for high-throughput DataChannels
    sctpMaxReceiveBufferSize: 4 * 1024 * 1024, // 4 MB

    // Restrict ICE to a specific UDP port range (useful behind firewalls)
    ephemeralUdpPortMin: 50000,
    ephemeralUdpPortMax: 51000,

    // Tune ICE failure detection
    iceDisconnectedTimeoutMs: 5000,
    iceFailedTimeoutMs: 25000,
    iceKeepaliveMs: 2000,
  ),
);
```

All fields are optional — omit any you don't need.

### Supported settings

**Boolean flags**

| Field | Pion method |
|-------|------------|
| `disableActiveTcp` | `DisableActiveTCP` |
| `disableCertificateFingerprintVerification` | `DisableCertificateFingerprintVerification` |
| `disableCloseByDtls` | `DisableCloseByDTLS` |
| `disableSrtcpReplayProtection` | `DisableSRTCPReplayProtection` |
| `disableSrtpReplayProtection` | `DisableSRTPReplayProtection` |
| `detachDataChannels` | `DetachDataChannels` (see [Detached data channels](#detached-data-channels)) |
| `enableDataChannelBlockWrite` | `EnableDataChannelBlockWrite` (**only with `detachDataChannels`**) |
| `enableSctpZeroChecksum` | `EnableSCTPZeroChecksum` |

**Numeric**

| Field | Pion method |
|-------|------------|
| `sctpMaxReceiveBufferSize` | `SetSCTPMaxReceiveBufferSize` |
| `sctpMaxMessageSize` | `SetSCTPMaxMessageSize` |
| `receiveMtu` | `SetReceiveMTU` |
| `iceMaxBindingRequests` | `SetICEMaxBindingRequests` |
| `dtlsReplayProtectionWindow` | `SetDTLSReplayProtectionWindow` |
| `srtcpReplayProtectionWindow` | `SetSRTCPReplayProtectionWindow` |
| `srtpReplayProtectionWindow` | `SetSRTPReplayProtectionWindow` |
| `ephemeralUdpPortMin` + `ephemeralUdpPortMax` | `SetEphemeralUDPPortRange` |

**Durations (milliseconds)**

| Field | Pion method |
|-------|------------|
| `iceDisconnectedTimeoutMs` + `iceFailedTimeoutMs` + `iceKeepaliveMs` | `SetICETimeouts` |
| `hostAcceptanceMinWaitMs` | `SetHostAcceptanceMinWait` |
| `srflxAcceptanceMinWaitMs` | `SetSrflxAcceptanceMinWait` |
| `prflxAcceptanceMinWaitMs` | `SetPrflxAcceptanceMinWait` |
| `relayAcceptanceMinWaitMs` | `SetRelayAcceptanceMinWait` |
| `dtlsRetransmissionIntervalMs` | `SetDTLSRetransmissionInterval` |
| `stunGatherTimeoutMs` | `SetSTUNGatherTimeout` |

**String**

| Field | Pion method |
|-------|------------|
| `multicastDnsHostName` | `SetMulticastDNSHostName` |

### Paired parameters

Two settings require all values in the group to be provided together or not at all — a partial set is rejected with an error:

- **UDP port range**: `ephemeralUdpPortMin` and `ephemeralUdpPortMax` must both be set.
- **ICE timeouts**: `iceDisconnectedTimeoutMs`, `iceFailedTimeoutMs`, and `iceKeepaliveMs` must all be set together.

### Limitations

Function-typed settings (`SetInterfaceFilter`, `SetIPFilter`, `SetVNet`, etc.) cannot be serialised over the wire and are not supported. Use them by forking the Go server directly if needed.

## Driving pion from worker isolates

`PionBridge.initialize()` calls a `MethodChannel` to spawn the native server, so it must run on the **root isolate**. To drive WebRTC from a worker isolate (e.g. to keep heavy DataChannel work off the UI thread), split the bootstrap from the connection:

```dart
// --- root isolate ---
final endpoint = await PionBridge.startServer();
Isolate.spawn(_workerEntry, {
  'sendPort': port.sendPort,
  'endpoint': endpoint.toMap(),
});

// --- worker isolate ---
Future<void> _workerEntry(Map args) async {
  final endpoint = PionServerEndpoint.fromMap(args['endpoint']);
  final pion = await PionBridge.connectExisting(endpoint);

  final pc = await pion.createPeerConnection();
  // … drive WebRTC entirely from the worker isolate
}
```

Both isolates can hold a `PionBridge` against the same Go server. Each gets its own WebSocket session, request-id stream, and event dispatcher; resources created in one isolate are owned by that isolate. Closing one bridge does not affect the other.

The convenience constructor `PionBridge.initialize()` is unchanged — it now internally calls `startServer()` followed by `connectExisting()`.

## Shared mode (desktop, in-process)

By default the bridge runs as it always has (`PionBridgeMode.websocket`): on desktop the plugin spawns the Go server as a sidecar process and Dart talks to it over a localhost WebSocket. `PionBridgeMode.shared` loads the same server as a shared library inside the app process instead, and passes the same msgpack frames through `dart:ffi` calls:

```dart
final bridge = await PionBridge.initialize(mode: PionBridgeMode.shared);
```

- No child process, no listening socket and no token. The Go runtime lives in the app process for its lifetime, so a Go crash is an app crash.
- It needs no `MethodChannel`, so it can be initialized directly from a worker isolate.
- There is nothing to reconnect to; the session lasts until `close()`.
- Desktop platforms (verified in VMs on all three):
  - **Linux:** `scripts/build_linux.sh` builds `linux/bundle/lib/libpionbridge.so`; the plugin bundles it into `lib/`.
  - **macOS:** `scripts/build_macos.sh` builds a universal `macos/Libraries/libpionbridge.dylib`; the podspec embeds it in `Contents/Frameworks`. It is currently *linked* (`vendored_libraries`), so the Go runtime loads at launch even in websocket mode.
  - **Windows:** `scripts/build_windows.sh` builds `windows/runner/resources/pionbridge.dll` (needs a MinGW-w64 gcc); the plugin installs it next to the `.exe`.
- Android/iOS already run the server in-process via gomobile, reached over the WebSocket; shared mode is not wired there.
- An app should load one Go shared library. Each carries its own Go runtime, and two runtimes in one process conflict.
- An app that links the bridge's `cshared` package into its own library needs neither the sidecar nor `libpionbridge`. On Linux and Windows, `set(PION_BRIDGE_BUNDLE_BINARIES OFF)` before the generated plugins are included. On macOS, set `PION_BRIDGE_BUNDLE_BINARIES=OFF` in the environment `flutter build macos` runs in, which drops the ~30 MB `pionbridge` sidecar from the app.

Where latency goes. Measured on Linux over loopback (200-byte DataChannel messages at 120 Hz, echoed by a Pion peer, median round trip):

| | Linux, UI isolate | Linux, worker isolate | macOS, UI isolate | Windows, UI isolate |
|---|---|---|---|---|
| websocket mode | 1.33 ms | 0.26–0.32 ms | 0.32 ms | 0.41 ms |
| shared mode | 1.27 ms | 0.18–0.21 ms | 0.26 ms | 0.35 ms |
| raw pion, Go only | — | 0.10 ms | — | — |

- **Go side:** the bridge adds about 30 µs per message over raw pion (`PROBE=1 go test -run TestProbeLatency ./internal/pionserver`).
- **Linux UI isolate:** the extra ~1 ms is specific to Flutter's Linux embedder; macOS and Windows UI isolates don't show it. On Linux, drive latency-sensitive traffic from a worker isolate.
- **Burst traffic on Windows:** shared mode ran a 20k-message burst at ~51k msg/s against ~6k msg/s over the localhost WebSocket.

## Detached data channels

`detachDataChannels: true` switches the Go side to pion's detached channels: the bridge
reads and writes each DataChannel directly instead of going through pion's callback read
loop, which is what makes writes block while the SCTP send buffer is full
(`enableDataChannelBlockWrite`, which pion ignores otherwise).

```dart
final bridge = await PionBridge.initialize(
  settingsEngine: const PionSettingsEngine(
    detachDataChannels: true,
    enableDataChannelBlockWrite: true,   // writes wait for buffer space
    sctpMaxReceiveBufferSize: 8 * 1024 * 1024,
  ),
);
```

- **The Dart API is unchanged.** Messages still arrive on `onMessage`, sends still go
  through `send`/`sendBinary`, and `onOpen`/`onClose`/`onBufferedAmountLow` still fire.
  (A detached channel is dropped from pion's own close notifications, so the bridge
  reports the close from its read loop.)
- **It applies to every channel** on connections created by that bridge — pion's
  granularity, not per channel.
- **Both transports support it**, websocket and shared mode, and so does gomobile.
- **What it is for:** bulk transfer. Blocking writes plus a large SCTP receive buffer pace
  the sender against the transport instead of queueing inside pion.
- **What it costs:** in a Partner spike, detaching made an *unordered, 0-retransmit*
  channel stall along with a busy reliable channel on a lossy link (~1 s p99 versus ~50 ms
  without detaching). Latency-sensitive traffic — input events, control messages — is
  better off on a non-detached bridge with a larger receive buffer.

## Media: codecs, transceivers and remote tracks

The protocol carries control, not media. An application that receives audio or
video declares what it can take, and handles the media itself in Go.

```dart
final bridge = await PionBridge.initialize(
  mode: PionBridgeMode.shared,
  sharedLibraryPath: myCombinedLibrary,
  mediaEngine: const PionMediaEngine(videoCodecs: ['AV1', 'VP9', 'VP8'], audioCodecs: ['opus']),
);
final pc = await bridge.createPeerConnection();
await pc.addTransceiver(MediaKind.video, TransceiverDirection.recvonly);
pc.onTrack.listen((t) => print('${t.kind} ${t.codec}'));
```

- **`PionMediaEngine`** registers only the listed codecs, in preference order,
  plus RTX for each video codec and pion's default interceptors (NACK, RTCP
  reports). Without one a connection has no media codecs — fine for data
  channels. It can be set per session or per connection, like
  `PionSettingsEngine`. Unknown names fail with `INVALID_MEDIA_ENGINE`.
- **`addTransceiver`** adds an m-line without a track. A `sendonly` transceiver
  still appears in the SDP, reserving a slot.
- **`onTrack`** reports each remote track (kind, ids, codec). The media itself
  never reaches Dart.

To process media, build **one** shared library containing the bridge and your
own Go code — a process can host only one Go runtime:

```go
package main

import (
	_ "github.com/gurupras/flutter-pion-bridge/go/cshared" // the PionBridge* exports
	"github.com/gurupras/flutter-pion-bridge/go/embed"
	"github.com/pion/webrtc/v4"
)

func init() {
	embed.OnTrack(func(pcHandle string, pc *webrtc.PeerConnection, t *webrtc.TrackRemote, r *webrtc.RTPReceiver) {
		go decode(pcHandle, t) // must not block
	})
	embed.OnPeerConnectionClosed(func(pcHandle string) { release(pcHandle) })
}

func main() {}
```

Pass that library as `sharedLibraryPath`. Without an `OnTrack` handler the
bridge drains tracks itself. On macOS, do not also bundle the bridge's own
`libpionbridge.dylib`: the podspec links whatever is in `macos/Libraries/`,
which would load a second Go runtime at launch.

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
