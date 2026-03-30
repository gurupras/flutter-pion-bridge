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
  }

  Stream<DataChannelMessage> get onMessage => _onMessage;
  Stream<void> get onOpen => _onOpen;
  Stream<void> get onClose => _onClose;

  Future<void> send(String data) async {
    await request('dc:send', {'data': data});
  }

  Future<void> sendBinary(List<int> data) async {
    await request('dc:send', {
      'data': data is Uint8List ? data : Uint8List.fromList(data),
    });
  }
}
