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

    _onOpen = onEvent()
        .where((msg) => msg.type == 'event:dataChannelOpen')
        .map((_) {
          onLog?.call('[DC:$label] opened');
          return null;
        });

    _onClose = onEvent()
        .where((msg) => msg.type == 'event:dataChannelClose')
        .map((_) {
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
  /// its send-buffer drains below [threshold] bytes.  Call once after the
  /// channel opens.  The high-water mark used for gating sends should be
  /// larger than [threshold] so there is hysteresis.
  Future<void> setBufferedAmountLowThreshold(int threshold) async {
    await request('dc:setBufferedAmountLowThreshold', {'threshold': threshold});
  }

  void send(String data) {
    connection.send('dc:send', handle, {'data': data});
  }

  void sendBinary(List<int> data) {
    connection.send('dc:send', handle, {
      'data': data is Uint8List ? data : Uint8List.fromList(data),
    });
  }
}
