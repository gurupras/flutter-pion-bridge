import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'buffered_broadcast.dart';
import 'event_dispatcher.dart';
import 'resource.dart';
import 'types.dart';
import 'bridge_connection.dart';
import 'ws_message.dart';

class PionDataChannel extends PionResource {
  final String label;
  final void Function(String)? onLog;

  // One eager subscription to this handle's event stream fans out into a
  // buffered stream per event type. Eager + per-type buffering makes event
  // delivery independent of the order (and timing) of the app's stream
  // subscriptions — see BufferedBroadcast.
  late final StreamSubscription<WsMessage> _eventSub;
  final _message = BufferedBroadcast<DataChannelMessage>();
  final _open = BufferedBroadcast<void>();
  final _close = BufferedBroadcast<void>();
  final _bufferedLow = BufferedBroadcast<void>();
  final _error = BufferedBroadcast<String>();

  PionDataChannel(
    String handle,
    BridgeConnection connection,
    EventDispatcher dispatcher, {
    this.label = '',
    this.onLog,
  }) : super(handle, connection, dispatcher) {
    _eventSub = onEvent().listen(_route);
  }

  void _route(WsMessage msg) {
    switch (msg.type) {
      case 'event:dataChannelMessage':
        final raw = msg.data['data'];
        final bool isBinary = msg.data['is_binary'] as bool? ?? false;
        final Uint8List bytes;
        if (raw is Uint8List) {
          bytes = raw;
        } else if (raw is List<int>) {
          bytes = Uint8List.fromList(raw);
        } else if (raw is String) {
          bytes = Uint8List.fromList(utf8.encode(raw));
        } else {
          bytes = Uint8List(0);
        }
        onLog?.call('[DC:$label] message ${bytes.length}B binary=$isBinary');
        _message.add(DataChannelMessage(bytes: bytes, isBinary: isBinary));
      case 'event:dataChannelOpen':
        onLog?.call('[DC:$label] opened');
        _open.add(null);
      case 'event:dataChannelClose':
        onLog?.call('[DC:$label] closed');
        _close.add(null);
      case 'event:bufferedAmountLow':
        _bufferedLow.add(null);
      case 'event:dc:error':
        _error.add((msg.data['error'] ?? '').toString());
    }
  }

  Stream<DataChannelMessage> get onMessage => _message.stream;
  Stream<void> get onOpen => _open.stream;
  Stream<void> get onClose => _close.stream;
  Stream<void> get onBufferedAmountLow => _bufferedLow.stream;
  Stream<String> get onError => _error.stream;

  @override
  bool disposeLocal() {
    if (!super.disposeLocal()) return false;
    _eventSub.cancel();
    _message.close();
    _open.close();
    _close.close();
    _bufferedLow.close();
    _error.close();
    return true;
  }

  /// Configures the native DataChannel to fire [onBufferedAmountLow] whenever
  /// its send-buffer drains below [threshold] bytes.  Note: as of v4.x the
  /// Dart-side backpressure for [sendBinary] is driven by the `dc:send` ack
  /// itself (which only fires once pion's send buffer is below threshold).
  /// This RPC is retained for backward-compatibility and telemetry — it
  /// adjusts the same internal threshold.
  Future<void> setBufferedAmountLowThreshold(int threshold) async {
    await request('dc:setBufferedAmountLowThreshold', {'threshold': threshold});
  }

  /// Send a UTF-8 text frame.  Returns once Go has confirmed the send (text
  /// frames ack as soon as the native send call returns — no buffered-low
  /// wait). [timeout] overrides the connection-wide request timeout for this
  /// call only.
  Future<void> send(String data, {Duration? timeout}) async {
    await request('dc:send', {'data': data}, timeout: timeout);
  }

  /// Send a binary frame.
  ///
  /// By default ([awaitDrain] = true) this returns only after pion's native
  /// send buffer has drained at or below the configured low-water threshold
  /// (see [setBufferedAmountLowThreshold], default 512 KB).  Callers that
  /// `await` this are implicitly throttled to the channel's drain rate,
  /// providing end-to-end backpressure without a separate flow-control layer.
  ///
  /// Set [awaitDrain] to false for fire-and-forget semantics: the returned
  /// Future completes as soon as the native [dc.Send] call returns, without
  /// waiting for the buffer to drain.
  ///
  /// [timeout] overrides the connection-wide request timeout (default 30s)
  /// for this call only. With [awaitDrain] the ack legitimately waits for the
  /// buffer to drain, so on slow links a large transfer can need more than
  /// the default before it is confirmed — pass a longer (or shorter) budget
  /// here rather than changing the global timeout.
  Future<void> sendBinary(
    List<int> data, {
    bool awaitDrain = true,
    Duration? timeout,
  }) async {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    await request('dc:send', {
      'data': bytes,
      if (!awaitDrain) 'await_drain': false,
    }, timeout: timeout);
  }
}
