import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:meta/meta.dart';
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
  final Duration connectTimeout;

  int _nextRequestId = 1;
  bool _connected = false;
  // Guards the disconnect path: an errored socket fires onError AND then
  // onDone, and manual close() must not trigger a reconnect. Without this a
  // single drop used to spawn two parallel reconnect loops.
  bool _disconnectHandled = false;

  WebSocketConnection({
    required this.onMessage,
    this.onDisconnect,
    this.requestTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
  });

  bool get isConnected => _connected;

  /// HttpClient whose connectionFactory disables Nagle on the underlying
  /// socket. dart:io leaves TCP_NODELAY off by default and gives no access
  /// to the socket of an established WebSocket, so the option has to be set
  /// at connect time. Go's side of the bridge already defaults to NoDelay;
  /// without this, pipelined small frames from Dart (dc:send requests,
  /// pings) can stall on Nagle + delayed-ACK interactions.
  static final io.HttpClient _httpClient = io.HttpClient()
    ..connectionFactory = (uri, proxyHost, proxyPort) {
      final task = io.Socket.startConnect(uri.host, uri.port);
      return task.then((t) {
        t.socket.then((socket) {
          socket.setOption(io.SocketOption.tcpNoDelay, true);
        }, onError: (_) {});
        return t;
      });
    };

  Future<void> connect(String url, {required String token}) async {
    final socket = await io.WebSocket.connect(
      url,
      headers: {'X-Pion-Token': token},
      customClient: _httpClient,
    ).timeout(connectTimeout, onTimeout: () {
      throw PionException(
          'CONNECTION_LOST', 'Timed out connecting to $url',
          fatal: true);
    });

    _channel = IOWebSocketChannel(socket);
    _connected = true;

    _subscription = _channel!.stream.listen(
      (message) => _handleMessage(message),
      onError: (error) => _handleDisconnect('WebSocket error: $error'),
      onDone: () => _handleDisconnect('WebSocket closed'),
    );
  }

  /// Test hook: drives the disconnect path directly. The production triggers
  /// (stream onError/onDone) can't be fired deterministically from a test.
  @visibleForTesting
  void debugHandleDisconnect(String reason) => _handleDisconnect(reason);

  void _handleDisconnect(String reason) {
    if (_disconnectHandled) return;
    _disconnectHandled = true;
    _connected = false;

    _failPending(reason);

    onDisconnect?.call();
  }

  void _failPending(String reason) {
    final pending = Map.of(_pendingRequests);
    _pendingRequests.clear();
    for (final completer in pending.values) {
      completer.completeError(
        PionException('CONNECTION_LOST', reason, fatal: true),
      );
    }
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
      final wsMsg = WsMessage.fromDecoded(decoded);

      if (wsMsg.type.endsWith(':ack') || wsMsg.type == 'error') {
        final completer = _pendingRequests.remove(wsMsg.id);
        if (completer != null) {
          if (wsMsg.type == 'error') {
            completer.completeError(PionException.fromWsMessage(wsMsg));
          } else {
            completer.complete(wsMsg.data);
          }
        } else if (wsMsg.id == 0) {
          // An ack the server chose to broadcast (fire-and-forget sends);
          // surface it as an event so nothing is silently dropped.
          onMessage(wsMsg);
        }
      } else {
        onMessage(wsMsg);
      }
    } catch (_) {
      // Malformed message — ignore rather than crashing
    }
  }

  /// Fire-and-forget send (id 0): no ack is awaited or correlated. Any ack
  /// the server broadcasts for id-0 sends is surfaced through [onMessage].
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
    Map<String, dynamic> data, {
    Duration? timeout,
  }) async {
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
      timeout ?? requestTimeout,
      onTimeout: () {
        _pendingRequests.remove(id);
        throw PionException('OPERATION_TIMEOUT', 'Request timed out');
      },
    );
  }

  Future<void> close() async {
    // Mark the disconnect as handled BEFORE tearing down the socket so a
    // trailing onDone can't trigger onDisconnect (and with it a reconnect).
    _disconnectHandled = true;
    _connected = false;
    _failPending('Connection closed');
    await _subscription?.cancel();
    await _channel?.sink.close();
  }
}
