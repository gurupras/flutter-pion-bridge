# Changelog

## Unreleased

- **SCTP: bounded SACKs.** Backports upstream pion/sctp 597b321 ("Bound
  outbound SACK packets by the MTU", not yet in a release) into the vendored
  fork. With a large receive buffer and scattered loss, SACKs outgrew the
  peer's read buffer, were dropped with "short buffer" errors, and the
  association died of T3 timeouts — reproduced at 8 MiB with tail-drop loss.
- **SCTP: upstream RTO constants restored.** The fork's rtoMin of 100 ms sat
  below the peer's 200 ms delayed-SACK timer, so an association that idles
  between messages took spurious T3 timeouts and dropped to a one-MTU cwnd.
  Several parallel connections sharing an 80 ms / 300 Mbit path delivered
  ~40 Mbps in total; with upstream's values they saturate it (~255 Mbps). The
  fork's test suite now passes in full.
- README: "Tuning DataChannel throughput" — receive window, transport-paced
  sends with detached blocking writes, and their caveats.

## 4.3.0

- **Shared mode (desktop).** `PionBridge.initialize(mode: PionBridgeMode.shared)`
  loads the bridge in-process over `dart:ffi` instead of spawning the sidecar and
  talking over a localhost WebSocket: no child process, no socket, no token, and it
  can start from any isolate. Linux bundles `libpionbridge.so`, macOS embeds a
  universal `libpionbridge.dylib`, and Windows installs `pionbridge.dll`
  (`scripts/build_*.sh` build them; the Windows DLL needs a MinGW-w64 gcc).
- **Media.** `PionMediaEngine` declares codecs per session or per connection
  (with RTX, pion's NACK/RTCP interceptors and `nackIntervalMs`); transceivers
  can be added without tracks; `event:track` reports remote tracks. Media never
  crosses the protocol: Go code linked into the same library registers track
  handlers through the new `embed` package, and the c-shared exports live in the
  importable `cshared` package so an app can ship one library with its own code.
- **Detached data channels** (`detach_data_channels`), which make blocking writes
  work and suit bulk transfer.
- **Settings per PeerConnection:** `createPeerConnection(settingsEngine: ...)`
  lets one bridge mix detached and attached connections.
- **Apps that ship their own library** can leave the sidecar and
  `libpionbridge` out of the bundle: `set(PION_BRIDGE_BUNDLE_BINARIES OFF)` on
  Linux and Windows, `PION_BRIDGE_BUNDLE_BINARIES=OFF` in the environment of
  `flutter build macos`.
- pion/webrtc v4.2.15; the SCTP RTO patch (`go/pion-sctp-patched`) is rebased
  onto pion/sctp v1.10.0.
- **Fixes:** the desktop sidecar now exits when the app dies however it dies
  (stdin pipe watchdog); the Windows plugin builds from an app (missing includes
  and C registrar); a clean Windows app build now bundles `pionbridge.exe` (it
  previously appeared only after a second CMake configure).
- Rebuilt bundled binaries for linux (amd64, arm64), windows, macOS (universal)
  and the iOS xcframework. The shared-mode libraries are not committed: build them
  with `scripts/build_*.sh` (a committed macOS dylib would be linked into every
  app, see the README).

## 4.2.3

Version-metadata correction. The `4.2.1` commit rebuilt the bundled binaries for
all platforms (macOS/iOS on a Mac, linux/windows/android via the latest
gomobile) but shipped without bumping `pubspec.yaml` or this changelog, and was
never tagged. This release fixes the version metadata so consumers resolve a
correct, tagged version. No source or binary changes since that rebuild — the
`iceTransportPolicy` feature landed in 4.2.0.

## 4.2.0

- **`iceTransportPolicy` support.** `PionBridge.createPeerConnection` now takes an
  `iceTransportPolicy` argument (`'all'` default, or `'relay'`), forwarded to the
  Go bridge (`ice_transport_policy` in `pc:create`), which sets
  `webrtc.Configuration.ICETransportPolicy`. `'relay'` forces ICE to gather and
  use ONLY relay (TURN) candidates — for forcing/proving the TURN data path (e.g.
  two NAT-permissive emulators whose server-reflexive candidates would otherwise
  win the ICE race and skip the relay).
- Rebuilt bundled **linux (amd64+arm64)** and **windows** binaries. Android is
  rebuilt from source by the consumer's Gradle `buildGoBridge` task, so it needs
  no committed artifact.
- **macOS binary / iOS xcframework are NOT yet rebuilt** here (Mac-only build).
  They ship stale until an artifact-only follow-up rebuilds them on a Mac — same
  split as 4.1.1 → 4.1.2.

## 4.1.2

Artifact-only release — no source changes.

- **Rebuilt the bundled macOS binary and iOS xcframework** with the 4.1.1
  read-path fix; 4.1.1 shipped stale ones (they can only be built on a Mac,
  which the release machine is not). The xcframework moves from the legacy
  `Versions/` symlink layout to the flat shallow-bundle layout current
  gomobile emits.
- Fixed `scripts/build_ios.sh`: the `gomobile bind` target still pointed at
  the pre-rename module path and the script could not run.

## 4.1.1

Performance release — no API or behavior changes.

- **WebSocket read path reuses one buffer per connection**: the Go server's
  read loop no longer allocates a fresh frame buffer per message
  (gorilla's `ReadMessage` → `io.ReadAll`, which was the single largest
  allocation site in the bridge under CPU-bound profiling at ~100k
  frames/s). It now reads each frame into a reused per-connection
  `bytes.Buffer` — safe because msgpack decoding copies every value out of
  the input, a library property now pinned by a regression test that
  scribbles over the buffer and asserts payload integrity. Measured on the
  profiling rig at the gigabit CPU ceiling (0 ms/4-connection cell):
  +14% throughput over 4.1.0, per-frame server allocation down 3.2×
  (215 KB → 68 KB per 64 KB frame), GC mark share down from ~23% to ~17%.

## 4.1.0

Bug-fix release from two full-codebase audit rounds, plus hot-path
performance work. No breaking changes.

### Second audit round — Go server

- **Fixed cascade delete skipping DataChannels**: deleting a PeerConnection
  with 3+ DataChannels silently skipped every other child (the cascade
  ranged over a slice its own recursion was mutating). Skipped children were
  never closed and their per-DC send goroutines leaked permanently.
- **Queued sends are failed, not abandoned, on close**: `dc:close` (or
  cascade teardown) now drains the per-DC send queue and answers each queued
  `dc:send` with a `DC_CLOSED` error; previously those callers' Futures hung
  forever.
- **The TTL sweeper spares connected-but-idle resources**: a healthy
  connection with no traffic for 300s (e.g. a control channel waiting on
  user action) was reaped. Resources whose PeerConnection is connected are
  now spared and refreshed; abandoned (never-connected) stale resources are
  still reaped.

### Second audit round — Dart

- **Event delivery no longer depends on stream subscription order**: each
  resource's events now fan out into per-type buffered streams. Previously
  the whole pre-subscription buffer was replayed to whichever derived stream
  (`onMessage`, `onOpen`, …) was listened to first, and later-subscribed
  streams silently missed their buffered events (a `dataChannelOpen` could
  vanish if `onMessage` was subscribed first). Events arriving between
  wrapper construction and the app's first `listen()` are also retained now.
- **`close()` during an in-flight reconnect attempt** no longer fires
  `onReconnected` after close or leaks the freshly connected socket.
- Closing a `PionPeerConnection` now disposes its DataChannels' local stream
  state too (mirroring the Go registry's cascade); closed-handle tombstones
  in the event dispatcher are bounded instead of growing forever.

### Second audit round — platform

- **Linux**: killed/exited Go child processes are now reaped (every hot
  restart used to leave a `<defunct>` zombie for the host's lifetime);
  process state is mutex-guarded against concurrent
  start/stop/dispose; the stdout pipe fd is closed on all teardown paths.
- **macOS**: a timed-out startup no longer drops a newer server process from
  tracking (leaking it); the termination handler no longer races
  platform-thread state.
- **Windows**: `stopServer` releases the stdout pipe read handle.

### Performance

- Removed a redundant 64 KB copy per uploaded binary chunk (one of four
  userspace passes over upload payloads — the defensive copy protected
  against message-pool reuse that provably cannot touch payload bytes).
- Registry activity tracking (`Touch`, on every inbound message and outbound
  event) now uses per-resource atomic timestamps with 1-second write
  coalescing instead of a global mutex — the read loop and every busy
  DataChannel's event goroutine no longer serialize on one lock.
- TCP_NODELAY is set on the Dart→Go loopback socket (dart:io leaves Nagle
  on; the Go side already defaulted to NoDelay).
- Cross-machine LAN A/B (9 interleaved pairs) confirms parity with the
  pre-fix baseline; the wins are CPU headroom and multi-DC scaling.

### Test-suite hardening (second round)

- Fixed a real test-harness race: each Dart integration test file (own
  process) rebuilt the shared Go test binary in place while other files were
  executing it (`ETXTBSY`/`ENOENT` flakes). Builds now serialize on a file
  lock and land via atomic rename, and the binary is no longer deleted
  mid-run.
- New red-first regression tests covering every fix above
  (`go/internal/pionserver/fixes2_regression_test.go`,
  `test/unit/fixes2_regression_test.dart`).

---

First audit round:

### Go server — reliability

- **Fixed a process crash on disconnect**: a `dc:send` ack (or
  `bufferedAmountLow` callback) racing a WebSocket disconnect used to panic
  with "send on closed channel" on a goroutine with no recover, killing the
  entire process. Connection teardown now uses a done-channel; frames
  enqueued after teardown are dropped safely.
- **Fixed cross-connection ack routing**: acks for `dc:send` issued on
  connection B were delivered to the connection that *created* the
  DataChannel (possibly already closed). Acks now go to the connection that
  issued the send — required for cross-isolate use.
- **Fixed the TTL sweeper reaping live connections**: `lastSeen` is now
  refreshed by outbound events (a receive-only DataChannel produces no
  inbound RPCs), and `Touch` refreshes the parent chain so an active DC
  keeps its PeerConnection alive.
- **Fixed a connection wedge on writer death**: if the WebSocket write side
  errored, producers could block forever on a full queue. The writer now
  closes the connection and unblocks all producers on exit.
- **Fixed text/binary reordering**: text `dc:send` ran inline while binary
  went through the per-DC queue, letting a text frame overtake queued binary
  frames. Both now share the per-DC FIFO (text still acks without waiting
  for buffer drain, but the ack is now asynchronous like binary).
- Registry no longer holds its lock across `pc.Close()`/`dc.Close()`
  (a teardown could stall all message processing for seconds), and lookups
  no longer take the write lock.
- Trace slots for DataChannels are released on close/delete (the handle→slot
  map grew unboundedly across DC churn) and are only allocated while tracing
  is enabled.
- `pc:addIce` no longer fabricates a non-nil empty `sdp_mid` when the field
  was absent.
- The desktop `pionbridge` child process exits on stdin EOF, so a crashed
  host no longer leaves orphaned servers behind.
- `mobile.Stop()` also stops the registry-cleanup goroutine;
  `Registry.StartCleanup` now returns a stop function.
- The `pion/sctp` replace in `go.mod` is no longer version-pinned (a pinned
  replace silently no-ops when the dependency is bumped, reverting the RTO
  patch the fork exists for) and the fork is documented in `go.mod`.

### Dart — reliability

- **Fixed reconnect storms**: a socket error fires the stream's `onError`
  *and* `onDone`; both invoked the disconnect handler, spawning two parallel
  reconnect loops that leaked sockets and delivered every event twice
  (doubling again on each subsequent drop). The disconnect path is now
  idempotent and reconnects are single-flight.
- **Events are no longer lost before subscription**: events arriving for a
  handle before anyone listens (e.g. `dataChannelOpen` on fast loopback) are
  buffered (up to 128 per handle/type) and replayed in order — since the
  second audit round, per event type, so delivery is independent of which
  stream the app subscribes first. Late events for explicitly closed handles
  are dropped.
- `PionBridge.close()` disposes all per-handle event stream controllers
  (previously they leaked, one per abandoned handle).
- `WebSocketConnection.close()` fails pending requests immediately instead
  of leaving them hanging until the 30-second request timeout.
- The initial WebSocket connect has a 10s timeout instead of hanging forever
  if the server never accepts.
- A malformed `event:dc:error` no longer surfaces as an unhandled stream
  error.
- `DataChannelMessage.text` no longer throws on non-UTF8 payloads (malformed
  sequences become U+FFFD).
- One map copy per inbound frame instead of three.

### Additive API — ICE interface control

- `PionSettingsEngine.interfaceWhitelist` (`interface_whitelist` on the wire)
  restricts ICE gathering to the named network interfaces, and
  `includeLoopbackCandidate` (`include_loopback_candidate`) enables loopback
  host candidates. Together they allow loopback-only operation
  (`interfaceWhitelist: ['lo'], includeLoopbackCandidate: true`) — used by
  the test suites for fast, deterministic in-process connections, and useful
  in production to pin ICE to specific interfaces.

### Found by on-device testing

- The desktop child's new stdin-EOF orphan watchdog only arms when stdin is
  actually a pipe held by the host. The Linux GTK plugin spawns the child
  with stdin as /dev/null, where reading returns EOF immediately — the
  unconditional watchdog killed a healthy server the instant it started.
- `android/build.gradle`: the gomobile jar file-dependency is now declared
  `builtBy 'buildGoBridge'`, fixing Gradle 8's implicit-dependency
  validation error that broke `assembleDebug` for consuming apps.
- The "second startServer" integration test now asserts each platform's
  actual contract: on desktop the old child process is killed and the first
  bridge disconnects; on Android/iOS the in-process listener restarts while
  established WebSockets deliberately survive. On mobile the test doubles as
  the hot-restart regression test.

### Test-suite hardening

- All connection-setup helpers (Go and Dart) now use trickle ICE —
  candidates are forwarded as they are gathered and the helpers wait for the
  DataChannel to actually open — instead of a fixed gather-sleep followed by
  a one-shot candidate exchange. The old pattern silently dropped candidates
  gathered after the sleep, making every ICE-dependent test flaky on hosts
  with many network interfaces (Docker/libvirt bridges) and under
  `go test -race`.
- Test peers connect over loopback only (via the new interface whitelist),
  cutting suite runtime roughly in half and making `-race` runs reliable.
- The vendored pion/sctp fork's tests now pass: three upstream tests assert
  RFC-default RTO timing that the fork's two-constant patch intentionally
  changes; they now pin the RFC value via the existing `setRTO` test hook
  (`pinUpstreamRTO`), and the RTO-calculation test asserts the fork's actual
  100ms floor.

### Dart — additive API

- `send`, `sendBinary`, and `PionResource.request` accept an optional
  `timeout:` override. With `awaitDrain: true` a large transfer on a slow
  link can legitimately need longer than the global 30s default to confirm —
  pass a per-call budget instead of raising the global timeout.

### Platform

- **iOS**: `startServer` stops any already-running server first (hot restart
  used to fail permanently with "server already running"); added a
  `stopServer` method.
- **Android**: `MethodChannel.Result` callbacks are now posted to the main
  thread (they were invoked from a background thread); concurrent
  `startServer` calls are serialized.
- **Linux**: `startServer` no longer blocks the GTK main thread for up to
  10 seconds; arm64 builds now bundle the arm64 binary instead of the amd64
  one.
- **Windows**: fixed a data race on the child-process handle between the
  startup thread and `stopServer`/teardown.
- **macOS**: the startup JSON is accumulated up to a newline instead of
  assuming it arrives in one read; the stderr handler no longer leaks.

## 4.0.0

### Breaking changes

- **`PionDataChannel.send(String)`** now returns `Future<void>` instead of
  `void`.  The returned Future completes once the Go side confirms the text
  send (synchronous ack).  Callers that used the old fire-and-forget form
  must either `await` the call or wrap it in `unawaited()`.

- **`PionDataChannel.sendBinary(List<int>)`** now returns `Future<void>`
  instead of `void`, and by default blocks until pion's native send buffer
  drains to at or below the configured low-water threshold (default 512 KB).
  This provides end-to-end backpressure: `await sendBinary(data)` means the
  data has actually left the kernel buffer, not merely been handed to pion.
  Pass `awaitDrain: false` to restore the old fire-and-forget behaviour.

- **Platform channel name changed** from `io.filemingo.pionbridge` to
  `io.pion_bridge.bridge`.  Native plugin implementations
  (`PionBridgePlugin` on Android, iOS, macOS, Linux, Windows) must update
  their channel registration to match.

### New features

- `PionDataChannel.sendBinary` accepts an optional `awaitDrain` parameter
  (default `true`).  Set to `false` for fire-and-forget semantics where
  latency matters more than backpressure.

- `PionDCConfig` — new class for per-session DataChannel send tunables:
  - `bufferedAmountLowThreshold` (default 512 KB)
  - `sendQueueDepth` (default 32)

  Pass via `PionSettingsEngine.dcConfig` in `PionBridge.initialize` /
  `PionBridge.connectExisting`.  Individual channels can further adjust the
  buffer threshold at runtime via
  `PionDataChannel.setBufferedAmountLowThreshold`.

- `NewHandlerWithConfig(registry, sendEvent, cfg DCConfig)` — Go-level
  constructor for callers that embed the pionserver package directly and want
  to set DC tunables without going through the WebSocket init message.

### Internal fixes (no API impact)

- DC send goroutine: ack-on-drain wait (`waitForBuffer`) is now skipped when
  `awaitDrain` is false, so fire-and-forget sends don't block the sender.
- `handleDCSend`: removed duplicate `event:dc:error` side-channel emission
  on the unknown-handle path; the typed `NOT_FOUND` error response is the
  only signal now.
- Fixed a within-DC send reordering race where back-to-back `dc:send` calls
  could reach `dc.Send` out of order.

## 3.1.0

- Add `PionBridge.startServer` + `connectExisting` for worker-isolate use.

## 3.0.0

- Reduce SCTP rtoMin/rtoInitial for faster retransmit convergence.
- Make pipeline tracing opt-in via `PionSettingsEngine.enableTracing`.
