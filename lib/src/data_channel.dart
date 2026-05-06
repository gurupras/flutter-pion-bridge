import 'dart:convert';
import 'dart:typed_data';

import 'event_dispatcher.dart';
import 'resource.dart';
import 'types.dart';
import 'websocket_connection.dart';

class PionDataChannel extends PionResource {
  final String label;
  final void Function(String)? onLog;
  late Stream<DataChannelMessage> _onMessage;
  late Stream<void> _onOpen;
  late Stream<void> _onClose;

  PionDataChannel(
    String handle,
    WebSocketConnection connection,
    EventDispatcher dispatcher, {
    this.label = '',
    this.onLog,
  }) : super(handle, connection, dispatcher) {
    _setupStreams();
  }

  late Stream<void> _onBufferedAmountLow;
  late Stream<String> _onError;

  void _setupStreams() {
    _onMessage = onEvent()
        .where((msg) => msg.type == 'event:dataChannelMessage')
        .map((msg) {
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
      return DataChannelMessage(bytes: bytes, isBinary: isBinary);
    });

    _onOpen =
        onEvent().where((msg) => msg.type == 'event:dataChannelOpen').map((_) {
      onLog?.call('[DC:$label] opened');
      return null;
    });

    _onClose =
        onEvent().where((msg) => msg.type == 'event:dataChannelClose').map((_) {
      onLog?.call('[DC:$label] closed');
      return null;
    });

    _onBufferedAmountLow = onEvent()
        .where((msg) => msg.type == 'event:bufferedAmountLow')
        .map((_) => null);

    _onError = onEvent()
        .where((msg) => msg.type == 'event:dc:error')
        .map((msg) => msg.data['error'] as String);
  }

  Stream<DataChannelMessage> get onMessage => _onMessage;
  Stream<void> get onOpen => _onOpen;
  Stream<void> get onClose => _onClose;
  Stream<void> get onBufferedAmountLow => _onBufferedAmountLow;
  Stream<String> get onError => _onError;

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
  /// path runs inline and acks synchronously — no buffered-low wait).
  Future<void> send(String data) async {
    await request('dc:send', {'data': data});
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
  Future<void> sendBinary(List<int> data, {bool awaitDrain = true}) async {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    await request('dc:send', {
      'data': bytes,
      if (!awaitDrain) 'await_drain': false,
    });
  }
}
