# Changelog

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
