# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**flutter-pion-bridge** is a Flutter plugin that exposes WebRTC `PeerConnection` and `DataChannel` APIs to Dart/Flutter apps via a Go (pion/webrtc) backend. The Go binary runs as an in-process WebSocket server; Dart communicates with it over a local WebSocket using MessagePack encoding.

## Build Commands

```bash
# Build Android AAR (gomobile bind → unpack into android/libs/ and android/src/main/jniLibs/)
./scripts/build_android.sh

# Build all platforms
./scripts/build_all.sh

# Other platform scripts follow the same pattern
./scripts/build_ios.sh
./scripts/build_linux.sh
./scripts/build_macos.sh
./scripts/build_windows.sh
```

Requirements for Android build:
- Go toolchain
- `gomobile`: `go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`
- `ANDROID_HOME` (default: `~/android-sdk-linux`)
- `ANDROID_NDK_HOME` (default: `$ANDROID_HOME/ndk/28.2.13676358`)

Build outputs for Android:
- `android/libs/pionbridge-go.jar` — Java bindings
- `android/src/main/jniLibs/<ABI>/libgojni.so` — native shared libraries (arm64-v8a, armeabi-v7a, x86_64)

**After any Go code change, you must rebuild the AAR and re-run the Flutter app.**

**Binaries are never committed.** Build outputs are gitignored; platform builds
use local outputs when present, otherwise download the release archives for the
`pubspec.yaml` version (`build_support/`). Every push to master is built and
e2e-tested by the Jenkins pipeline (`Jenkinsfile`, `tooling/ci/`), which
releases the version in `pubspec.yaml` when it has no tag yet — see
`RELEASING.md`.

## Architecture

### Communication Flow

```
Flutter app (Dart)
  ↓ MethodChannel 'io.filemingo.pionbridge' → startServer
  ↓ returns { port, token }
  ↓
WebSocket ws://127.0.0.1:<port>/ (token in X-Pion-Token header)
  ↓ MessagePack binary frames
Go pionserver (WebSocket server, pion/webrtc)
```

### Message Protocol (MessagePack)

All messages are maps with fields: `type`, `id`, `handle`, `data`.

- **Requests** (Dart → Go): `type` = command string, `id` = incrementing int, `handle` = resource UUID, `data` = params
- **Responses** (Go → Dart): `type` = `<command>:ack` or `"error"`, same `id` as request
- **Events** (Go → Dart): `type` = `"event:<name>"`, `id` = 0, `handle` = resource handle that fired the event

### Go Server (`go/internal/pionserver/`)

| File | Purpose |
|------|---------|
| `server.go` | WebSocket server, message read loop, ping/pong keepalive |
| `handler.go` | Routes message types to handlers; all RPC logic here |
| `registry.go` | Thread-safe handle→resource map; parent/child tracking (PC→DC); TTL cleanup (connected PCs and their children are spared; activity stamps are per-resource atomics) |
| `types.go` | `Message` struct, `AckResponse`, `ErrorResponse`, `Event` helpers |

**Serial message processing**: the server's read loop processes one message at a time (no goroutine per message). Event callbacks (ICE, OnMessage, etc.) run on pion's goroutines and call `sendEvent`, which enqueues onto a per-connection `connWriter`; a single writer goroutine performs all WebSocket writes. After disconnect, enqueues return `errConnClosed` and are dropped safely (never panic). Outbound events also refresh the handle's TTL (`registry.Touch` walks the parent chain), so receive-only resources are not reaped by the cleanup sweeper.

**SCTP fork**: `go/pion-sctp-patched/` is upstream pion/sctp with exactly two constants changed for loopback latency (`rtoInitial` 1000→200ms, `rtoMin` 1000→100ms in `rtx_timer.go`). The `replace` in `go.mod` is deliberately unversioned; rebase the patch when bumping pion/webrtc.

### Dart Library (`lib/src/`)

| File | Purpose |
|------|---------|
| `bridge.dart` | `PionBridge` — top-level entry point; starts Go server via MethodChannel, opens WebSocket |
| `websocket_connection.dart` | `WebSocketConnection` — msgpack send/receive, request/response correlation by ID |
| `reconnect.dart` | `ReconnectingWebSocketConnection` — wraps `WebSocketConnection` with retry logic |
| `event_dispatcher.dart` | `EventDispatcher` — routes incoming events to per-handle stream subscribers |
| `resource.dart` | `PionResource` — base class with `request()` and `onEvent()` helpers |
| `peer_connection.dart` | `PionPeerConnection` — wraps PC RPC calls and event streams |
| `data_channel.dart` | `PionDataChannel` — wraps DC RPC calls and event streams |
| `types.dart` | `IceCandidate`, `ConnectionState`, `IceServer`, `DataChannelMessage` |
| `ws_message.dart` | `WsMessage` — msgpack map serialization |
| `exception.dart` | `PionException` |

### RPC Commands

| Command | Direction | Purpose |
|---------|-----------|---------|
| `pc:create` | → Go | Create PeerConnection |
| `pc:offer` / `pc:answer` | → Go | Create SDP offer/answer |
| `pc:setLocalDesc` / `pc:setRemoteDesc` | → Go | Set SDP |
| `pc:addIce` | → Go | Add ICE candidate |
| `pc:createDc` | → Go | Create DataChannel |
| `pc:close` | → Go | Close PeerConnection |
| `dc:send` | → Go | Send text or binary data via the per-DC FIFO queue — the ack is **asynchronous** (emitted by the per-DC goroutine, routed to the connection that issued the send). Binary sends with `await_drain` (default) ack only after pion's buffer drains below the low-water mark; text sends ack as soon as `SendText` returns. Errors arrive as an `error` response plus `event:dc:error` |
| `dc:setBufferedAmountLowThreshold` | → Go | Set backpressure threshold + hook `OnBufferedAmountLow` |
| `dc:close` | → Go | Close DataChannel |
| `resource:delete` | → Go | Delete handle from registry |

### Events (Go → Dart)

| Event type | Fired by |
|-----------|---------|
| `event:iceCandidate` | `pc.OnICECandidate` |
| `event:iceGatheringComplete` | `pc.OnICECandidate(nil)` |
| `event:connectionStateChange` | `pc.OnConnectionStateChange` |
| `event:dataChannel` | `pc.OnDataChannel` |
| `event:dataChannelOpen` | `dc.OnOpen` |
| `event:dataChannelClose` | `dc.OnClose` |
| `event:dataChannelMessage` | `dc.OnMessage` |
| `event:bufferedAmountLow` | `dc.OnBufferedAmountLow` |
| `event:dc:error` | `dc.Send` / `dc.SendText` failure, or invalid `dc:send` payload |

### Backpressure

`dc:send` is fire-and-forget — Dart does not wait for Go to confirm each send. To avoid overrunning the native send buffer:

1. Call `setBufferedAmountLowThreshold(threshold)` once after the DataChannel opens.
2. Gate sends on a high-water mark: pause when `dc.bufferedAmount > highWaterMark`.
3. Resume sending when `onBufferedAmountLow` fires.

Errors from `dc.Send` (e.g. channel not open, connection broken) arrive on `onError`. A connection-level failure will also fire `onConnectionStateChange` with `failed`/`disconnected`.

### Adding a New RPC Command

1. Add a `case "cmd:name":` in `handler.go`'s `HandleMessage` switch
2. Write `handleCmdName(msg *Message) Message` following existing patterns
3. Add a Dart method in the appropriate `lib/src/*.dart` file calling `request('cmd:name', {...})`
4. Rebuild the AAR: `./scripts/build_android.sh`

## Testing

Run **all** of these layers before declaring a change done — host-green is
not device-safe (a compiling, host-test-green change has been fatally broken
on a real device path before):

```bash
# 1. Go server — plain AND with the race detector
cd go && go test ./internal/pionserver/ -count=1
cd go && go test ./internal/pionserver/ -race -count=1

# 2. Vendored pion/sctp fork — it is a SEPARATE module; ./pion-sctp-patched/...
#    from go/ fails with "does not contain package"
cd go/pion-sctp-patched && go test . -count=1

# 3. Dart unit + integration (integration spawns the real Go binary)
flutter test test/unit/ test/integration/

# 4. On-device (example app, full MethodChannel → native → Go stack)
./scripts/build_android.sh   # ALWAYS rebuild the AAR first after Go changes
cd example && flutter test --device-id <android-device> integration_test/plugin_integration_test.dart
./scripts/build_linux.sh
cd example && flutter test --device-id linux integration_test/plugin_integration_test.dart

# 5. Cross-platform e2e (every platform × bridge mode, against packaged archives)
#    runs in the Jenkins pipeline; locally: scripts/package_release.sh linux-x64
#    && tooling/ci/e2e/linux.sh — see RELEASING.md
```

### Test conventions (do not regress these)

- **Never use fixed sleeps for ICE setup in tests.** On hosts with many
  network interfaces (Docker/libvirt bridges), gathering outlives any fixed
  sleep and a one-shot candidate exchange silently drops candidates —
  causing flaky-or-failing connections, especially under `-race`. Use
  trickle ICE (forward candidates as they arrive) and wait on
  `dataChannelOpen`/`connected` events. All existing helpers
  (`createConnectedPCPair`, `setupConnectedDCPair`, Dart
  `TestHarness.createConnectedPair`) already do this.
- **Test peers use loopback-only ICE** via
  `settings_engine: {interface_whitelist: ["lo"], include_loopback_candidate: true}`
  (Dart: `PionSettingsEngine.interfaceWhitelist` / `includeLoopbackCandidate`).
  In-process peers only need 127.0.0.1; this makes connection setup instant
  and deterministic on any machine.
- **Flaky tests are real bugs** — root-cause them; do not retry, loosen, or
  skip. Bug fixes are test-first: write the regression test, confirm it
  fails on the unfixed code, then fix.

### Cross-machine benchmark (non-loopback verification)

`tool/remote_bench_client.dart` + `go/cmd/benchpeer` measure connect time,
bidirectional throughput, and DataChannel RTT across a real network path —
the one thing the loopback suites cannot cover (and where the SCTP fork's
lowered RTO floor carries risk):

```bash
# Remote machine (only needs the static binary):
cd go && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o benchpeer ./cmd/benchpeer
scp benchpeer <remote>:… && ssh <remote> ./benchpeer --port 8765

# Local machine (full Dart+Go stack under test):
cd go && go build -o /tmp/pionbridge . && cd ..
dart run tool/remote_bench_client.dart --signaling ws://<remote>:8765 --bin /tmp/pionbridge
```

The client is deliberately source-compatible with v4.0.0 so A/B runs against
a baseline checkout work (git stash keeps the untracked tool in place).
There is also `example/integration_test/remote_benchmark_test.dart` for
running the device side on Android (`SIGNALING` dart-define; the emulator
reaches the host at 10.0.2.2) — but note the emulator's slirp NAT stalls
bulk UDP uploads, so prefer a physical device or the pure-Dart client for
throughput numbers. Reference (wired gigabit LAN, 2026-07): ~800 Mbps up,
~700 Mbps down, ~0.37 ms DC RTT, ~1s connect.

### Platform semantics to remember

- **Second `startServer` differs by platform**: desktop kills and respawns
  the Go child process (existing bridges disconnect); Android/iOS restart
  the in-process gomobile listener and established WebSockets deliberately
  survive. Tests asserting either behavior must be platform-conditional.
- **The desktop child's stdin watchdog** (`go/main.go`) exits on stdin EOF
  only when stdin is a real pipe. Hosts that spawn it with `/dev/null` stdin
  (the Linux GTK plugin) get no orphan protection — do not "simplify" the
  pipe check away, it prevented the watchdog from killing healthy servers.
- The `pion/sctp` fork keeps upstream's RTO constants (see the comment in
  `go/go.mod`). Do not lower rtoMin below the peer's 200 ms delayed-SACK
  timer: application-limited associations then take spurious T3 timeouts and
  collapse to a one-MTU cwnd — measured as a ~6× throughput loss for several
  connections sharing one link.

## Git Workflow

Per `CLAUDE.md` at repo root:
- Do NOT add `Co-Authored-By` attribution to commits
- Do NOT set `-c user.name` or `-c user.email`; use existing git config
