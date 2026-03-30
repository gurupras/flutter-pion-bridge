import 'dart:typed_data';

import 'event_dispatcher.dart';
import 'resource.dart';
import 'types.dart';
import 'websocket_connection.dart';

class PionDataChannel extends PionResource {
  final String label;
  late Stream<DataChannelMessage> _onMessage;
  late Stream<void> _onOpen;
  late Stream<void> _onClose;

  PionDataChannel(
    String handle,
    WebSocketConnection connection,
    EventDispatcher dispatcher, {
    this.label = '',
  }) : super(handle, connection, dispatcher) {
    _setupStreams();
  }

  late Stream<void> _onBufferedAmountLow;

  void _setupStreams() {
    _onMessage = onEvent()
        .where((msg) => msg.type == 'event:dataChannelMessage')
        .map((msg) => DataChannelMessage(
              data: msg.data['data'] as String,
              isBinary: msg.data['is_binary'] as bool? ?? false,
            ));

    _onOpen = onEvent()
        .where((msg) => msg.type == 'event:dataChannelOpen')
        .map((_) => null);

    _onClose = onEvent()
        .where((msg) => msg.type == 'event:dataChannelClose')
        .map((_) => null);

    _onBufferedAmountLow = onEvent()
        .where((msg) => msg.type == 'event:bufferedAmountLow')
        .map((_) => null);
  }

  Stream<DataChannelMessage> get onMessage => _onMessage;
  Stream<void> get onOpen => _onOpen;
  Stream<void> get onClose => _onClose;
  Stream<void> get onBufferedAmountLow => _onBufferedAmountLow;

  /// Configures the native DataChannel to fire [onBufferedAmountLow] whenever
  /// its send-buffer drains below [threshold] bytes.  Call once after the
  /// channel opens.  The high-water mark used for gating sends should be
  /// larger than [threshold] so there is hysteresis.
  Future<void> setBufferedAmountLowThreshold(int threshold) async {
    await request('dc:setBufferedAmountLowThreshold', {'threshold': threshold});
  }

  Future<void> send(String data) async {
    await request('dc:send', {'data': data});
  }

  Future<void> sendBinary(List<int> data) async {
    await request('dc:send', {
      'data': data is Uint8List ? data : Uint8List.fromList(data),
    });
  }
}
