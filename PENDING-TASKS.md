# Pending Tasks

Phases 1 and 2 are implemented. Phase 3 (hardening) remains.

---

## Phase 1 — MVP (offer/answer flow, no data channels)

### Go Server
- [x] Project scaffolding (`go.mod`, deps: `pion/webrtc`, `vmihailenco/msgpack/v5`, `gorilla/websocket`)
- [x] Resource Registry — thread-safe handle map with UUID generation and last-seen tracking
- [x] Session token generation (UUID v4 hex, 32 chars)
- [x] WebSocket server on `127.0.0.1:0`, token validation on upgrade (`X-Pion-Token` header, 401 on failure)
- [x] Startup stdout JSON: `{"port": <int>, "token": "<hex>"}`
- [x] MessagePack encode/decode for all messages
- [x] Panic recovery middleware (`defer recover()` → `FATAL_PANIC` error response)
- [x] Message router dispatching on `type` field
- [x] Operations:
  - [x] `init` — session verification (optional, returns version)
  - [x] `pc:create` — create PeerConnection from ice_servers/bundle_policy/rtcp_mux_policy, return handle
  - [x] `pc:offer` — create SDP offer, return sdp
  - [x] `pc:answer` — create SDP answer, return sdp
  - [x] `pc:setLocalDesc` — set local description
  - [x] `pc:setRemoteDesc` — set remote description
  - [x] `pc:addIce` — add ICE candidate
  - [x] `pc:close` — close PeerConnection (keep handle in registry)
  - [x] `resource:delete` — close + deregister from registry
- [x] Events (fire-and-forget, `id: 0`):
  - [x] `event:iceCandidate` — forward ICE candidates to Dart
  - [x] `event:iceGatheringComplete` — signal gathering done
  - [x] `event:connectionStateChange` — forward connection state changes
- [x] Request/response ID matching (echo back request `id` in `:ack` responses)

### Platform Glue
- [x] Android: Kotlin plugin to start Go binary, capture stdout JSON, expose via MethodChannel
- [x] MethodChannel `io.filemingo.pionbridge` with `startServer()` method returning `{port, token}`

### Dart Layer
- [x] `WsMessage` — type/id/handle/data model with `toMap()`/`fromMap()`
- [x] `WebSocketConnection` — connect with token header (`dart:io` WebSocket), MessagePack codec, request/response matching, pending request timeout (30s), disconnection detection (`CONNECTION_LOST`), `onDisconnect` callback, `isConnected` getter
- [x] `EventDispatcher` — route `WsMessage` to per-handle `StreamController<WsMessage>` listeners
- [x] `PionResource` — base class with handle, request(), onEvent(), close()
- [x] `PionException` — code/message/fatal/handle, factory from WsMessage
- [x] `PionBridge` — `initialize()` (start server via MethodChannel, connect WS), `createPeerConnection()`, `close()`
- [x] `PionPeerConnection` — streams (`onIceCandidate`, `onIceGatheringComplete`, `onConnectionStateChange`), methods (`createOffer`, `createAnswer`, `setLocalDescription`, `setRemoteDescription`, `addIceCandidate`)
- [x] Helper types: `IceServer`, `IceCandidate`, `ConnectionState` (with `fromString` for "new" mapping)
- [x] `pubspec.yaml` with `msgpack_dart` dependency

---

## Phase 2 — Data Channels

### Go Server
- [x] Operations:
  - [x] `pc:createDc` — create DataChannel on a PeerConnection, return `dc_handle`
  - [x] `dc:send` — send text or base64-encoded binary data
  - [x] `dc:close` — close DataChannel (keep handle in registry)
- [x] Events:
  - [x] `event:dataChannel` — remote peer opened a DataChannel
  - [x] `event:dataChannelOpen` — DataChannel opened
  - [x] `event:dataChannelClose` — DataChannel closed
  - [x] `event:dataChannelMessage` — incoming message (text or binary with `is_binary` flag)
- [x] Resource cleanup: background goroutine every 30s, delete handles with `lastSeen > 300s`
- [x] Reference counting: deleting a PeerConnection cascades to its DataChannels

### Dart Layer
- [x] `PionDataChannel` — streams (`onMessage`, `onOpen`, `onClose`), methods (`send`, `sendBinary`)
- [x] `DataChannelMessage` — wraps text/binary with `isBinary` flag, `binaryData` getter
- [x] `PionPeerConnection.createDataChannel()` and `onDataChannel` stream

---

## Testing

### Go Unit Tests (`go/*_test.go`)

#### Registry Tests
- [x] Register returns valid 32-char hex handle
- [x] Lookup returns resource and updates lastSeen
- [x] Lookup of unknown handle returns false
- [x] Delete removes resource and calls Close()
- [x] Delete of unknown handle returns error
- [x] RegisterChild links child to parent
- [x] Delete parent cascades to children
- [x] Cleanup removes stale handles (lastSeen > maxAge)
- [x] Cleanup leaves fresh handles alone
- [x] Concurrent Register/Lookup/Delete (race detector)

#### Handler Tests (per operation, using real Pion objects)
- [x] `init` — returns version ack
- [x] `pc:create` — returns handle + state "new"
- [x] `pc:create` with ICE servers — config passed through correctly
- [x] `pc:offer` — returns SDP string
- [x] `pc:answer` — returns SDP string (after remote offer set)
- [x] `pc:setLocalDesc` / `pc:setRemoteDesc` — returns signaling state
- [x] `pc:setLocalDesc` with missing fields — returns INVALID_REQUEST
- [x] `pc:addIce` — succeeds with valid candidate
- [x] `pc:addIce` with missing candidate — returns INVALID_REQUEST
- [x] `pc:close` — succeeds, handle still in registry
- [x] `pc:createDc` — returns dc_handle + label
- [x] `pc:createDc` with missing label — returns INVALID_REQUEST
- [x] `dc:send` text — returns bytes_sent
- [x] `dc:send` binary (base64) — returns bytes_sent
- [x] `dc:send` invalid base64 — returns INVALID_REQUEST
- [x] `dc:close` — succeeds
- [x] `resource:delete` — removes handle from registry
- [x] `resource:delete` on PeerConnection — cascades to DataChannels
- [x] Unknown message type — returns INVALID_REQUEST
- [x] Operation on wrong handle type (e.g. pc:offer on DC handle) — returns INVALID_REQUEST
- [x] Operation on non-existent handle — returns NOT_FOUND

#### Server Tests
- [x] Token validation — valid token upgrades to WebSocket
- [x] Token validation — invalid token returns 401
- [x] Token validation — missing token returns 401
- [x] Full round-trip: connect → send msgpack request → receive msgpack ack
- [x] Non-binary WebSocket message — returns INVALID_REQUEST
- [x] Malformed msgpack — returns INVALID_REQUEST
- [x] Panic recovery — handler panic returns FATAL_PANIC error (not crash)

#### Event Callback Tests
- [x] `event:connectionStateChange` fires on state transitions
- [x] `event:iceCandidate` fires with correct fields when ICE candidate gathered
- [x] `event:iceGatheringComplete` fires when candidate is nil
- [x] `event:dataChannel` fires when remote opens DC (includes dc_handle, label)
- [x] `event:dataChannelOpen` fires when DC opens
- [x] `event:dataChannelClose` fires when DC closes
- [x] `event:dataChannelMessage` fires for text messages
- [x] `event:dataChannelMessage` fires for binary messages (base64-encoded, is_binary=true)

Note: event callback tests require two fully-connected PeerConnections (SCTP established), which is covered by the integration test.

### Go Integration / Smoke Test (`go/integration_test.go`)

End-to-end test that mimics what the Dart client does over a real WebSocket:

- [x] Start server on ephemeral port, parse startup JSON
- [x] Connect WebSocket with valid token
- [x] Send `init`, verify `init:ack` with version
- [x] Create two PeerConnections (offerer + answerer)
- [x] Offerer: createOffer → setLocalDesc
- [x] Answerer: setRemoteDesc (offerer's offer) → createAnswer → setLocalDesc
- [x] Offerer: setRemoteDesc (answerer's answer)
- [x] Exchange ICE candidates between both PCs via `pc:addIce`
- [x] Verify `event:connectionStateChange` reaches "connected" on both sides
- [x] Create DataChannel on offerer, verify `event:dataChannel` on answerer
- [x] Send text message, verify `event:dataChannelMessage` on receiver
- [x] Send binary message, verify base64 + is_binary=true on receiver
- [x] Close DataChannel, verify `event:dataChannelClose`
- [x] `resource:delete` PeerConnection, verify cascade deletes DataChannel
- [x] Disconnect WebSocket, verify server doesn't crash

### Dart System Tests (`test/`)

Full end-to-end tests that build the Go server binary, start it as a subprocess (bypassing MethodChannel), and exercise the Dart layer against it over a real WebSocket:

#### Setup
- [x] Test harness: build Go binary, start as subprocess, parse stdout JSON, connect `WebSocketConnection` directly (no MethodChannel)

#### Connection & Lifecycle
- [x] Connect with valid token — isConnected is true
- [x] Connect with invalid token — throws or fails to connect
- [x] Disconnect detection — onDisconnect fires when server killed
- [x] Disconnect fails pending requests with CONNECTION_LOST
- [x] Request after disconnect throws CONNECTION_LOST
- [x] Request timeout with no response — throws OPERATION_TIMEOUT

#### PeerConnection Operations
- [x] createPeerConnection returns PionPeerConnection with valid handle
- [x] createOffer returns SDP string
- [x] createAnswer returns SDP string (after setting remote offer)
- [x] setLocalDescription / setRemoteDescription complete without error
- [x] addIceCandidate completes without error
- [x] onIceCandidate stream emits IceCandidate objects
- [x] onIceGatheringComplete stream emits after all candidates
- [x] onConnectionStateChange stream emits ConnectionState values
- [x] close() sends resource:delete and cleans up dispatcher

#### Full Offer/Answer Flow
- [x] Two PeerConnections complete full offer/answer/ICE exchange
- [x] Both reach ConnectionState.connected

#### DataChannel Operations
- [x] createDataChannel returns PionDataChannel with handle and label
- [x] onDataChannel stream emits when remote creates DC
- [x] send() delivers text to remote via onMessage
- [x] sendBinary() delivers binary (base64-decoded) to remote via onMessage
- [x] DataChannelMessage.isBinary is correct for text vs binary
- [x] onOpen stream emits when DC opens
- [x] onClose stream emits when DC closes
- [x] close() on DataChannel sends resource:delete

#### Error Handling
- [x] Operation on non-existent handle throws PionException with NOT_FOUND
- [x] PionException.code and .message populated correctly
- [x] PionException.fatal is true for FATAL_PANIC / CONNECTION_LOST

#### Serialization (in `test/unit_test.dart`)
- [x] WsMessage.toMap() / fromMap() round-trips correctly
- [x] EventDispatcher routes events to correct handle
- [x] EventDispatcher ignores events for unregistered handles
- [x] ConnectionState.fromString("new") returns newConnection
- [x] ConnectionState.fromString("connected") returns connected

---

## Phase 3 — Hardening

- [x] Comprehensive error handling across all operations
  - Go: panic recovery in all WebRTC callbacks (OnICECandidate, OnConnectionStateChange, OnDataChannel, OnOpen, OnClose, OnMessage)
  - Go: Close() errors logged (not silently discarded)
  - Go: json.Marshal error in main.go is now fatal instead of silent
  - Dart: safe msgpack deserialization (try/catch, non-Map responses dropped)
  - Dart: safe null-tolerant type coercion in PionException.fromWsMessage
  - Dart: safe field access in peer_connection.dart stream maps
  - Android: stderr drained to logcat, startup timeout (10s), process killed on error
- [x] WebSocket keepalive / ping-pong mechanism
  - Go server sends WebSocket ping every 15s; expects pong within 30s (read deadline reset on pong)
  - requestTimeout on WebSocketConnection is now configurable (default 30s)
- [ ] WebSocket reconnection with exponential backoff
- [ ] Platform-specific build scripts (Android NDK Go cross-compile, iOS gomobile, Linux/macOS/Windows native)
