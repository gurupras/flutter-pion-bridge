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
| `registry.go` | Thread-safe handle→resource map; parent/child tracking (PC→DC); TTL cleanup |
| `types.go` | `Message` struct, `AckResponse`, `ErrorResponse`, `Event` helpers |

**Serial message processing**: the server's read loop processes one message at a time (no goroutine per message). Event callbacks (ICE, OnMessage, etc.) run on pion's goroutines and call `sendEvent` which acquires `s.mu` before writing.

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
| `dc:send` | → Go | Send text or binary data — **fire-and-forget** (no ack); errors arrive as `event:dc:error` |
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

## Git Workflow

Per `CLAUDE.md` at repo root:
- Do NOT add `Co-Authored-By` attribution to commits
- Do NOT set `-c user.name` or `-c user.email`; use existing git config
