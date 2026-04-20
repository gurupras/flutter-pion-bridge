import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:web_socket_channel/io.dart';

import 'exception.dart';
import 'ws_message.dart';

class WebSocketConnection {
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final void Function(WsMessage) onMessage;
  final void Function()? onDisconnect;
  final Duration requestTimeout;

  int _nextRequestId = 1;
  bool _connected = false;

  WebSocketConnection({
    required this.onMessage,
    this.onDisconnect,
    this.requestTimeout = const Duration(seconds: 30),
  });

  bool get isConnected => _connected;

  Future<void> connect(String url, {required String token}) async {
    final socket = await io.WebSocket.connect(
      url,
      headers: {'X-Pion-Token': token},
    );

    _channel = IOWebSocketChannel(socket);
    _connected = true;

    _subscription = _channel!.stream.listen(
      (message) => _handleMessage(message),
      onError: (error) => _handleDisconnect('WebSocket error: $error'),
      onDone: () => _handleDisconnect('WebSocket closed'),
    );
  }

  void _handleDisconnect(String reason) {
    _connected = false;

    final pending = Map.of(_pendingRequests);
    _pendingRequests.clear();
    for (final completer in pending.values) {
      completer.completeError(
        PionException('CONNECTION_LOST', reason, fatal: true),
      );
    }

    onDisconnect?.call();
  }

  void _handleMessage(dynamic message) {
    final Uint8List bytes;
    if (message is Uint8List) {
      bytes = message;
    } else if (message is List<int>) {
      bytes = Uint8List.fromList(message);
    } else {
      return;
    }

    try {
      final decoded = msgpack.deserialize(bytes);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      final wsMsg = WsMessage.fromMap(map);

      if (wsMsg.type.endsWith(':ack') || wsMsg.type == 'error') {
        final completer = _pendingRequests.remove(wsMsg.id);
        if (completer != null) {
          if (wsMsg.type == 'error') {
            completer.completeError(PionException.fromWsMessage(wsMsg));
          } else {
            completer.complete(wsMsg.data);
          }
        }
      } else {
        onMessage(wsMsg);
      }
    } catch (_) {
      // Malformed message — ignore rather than crashing
    }
  }

  void send(String type, String? handle, Map<String, dynamic> data) {
    if (!_connected) {
      throw PionException('CONNECTION_LOST', 'WebSocket is not connected',
          fatal: true);
    }
    final msg = WsMessage(type: type, id: 0, handle: handle, data: data);
    _channel!.sink.add(msgpack.serialize(msg.toMap()));
  }

  Future<Map<String, dynamic>> request(
    String type,
    String? handle,
    Map<String, dynamic> data,
  ) async {
    if (!_connected) {
      throw PionException('CONNECTION_LOST', 'WebSocket is not connected',
          fatal: true);
    }

    final id = _nextRequestId++;
    final msg = WsMessage(
      type: type,
      id: id,
      handle: handle,
      data: data,
    );

    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final encoded = msgpack.serialize(msg.toMap());
    _channel!.sink.add(encoded);

    return completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pendingRequests.remove(id);
        throw PionException('OPERATION_TIMEOUT', 'Request timed out');
      },
    );
  }

  Future<void> close() async {
    _connected = false;
    await _subscription?.cancel();
    await _channel?.sink.close();
  }
}
