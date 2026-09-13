import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:web_socket_channel/io.dart';

import 'bridge_connection.dart';
import 'exception.dart';

/// Protocol session over a localhost WebSocket to the Go server — the sidecar
/// process on desktop, the gomobile in-process server on Android/iOS.
class WebSocketConnection extends BridgeConnection {
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final void Function()? onDisconnect;
  final Duration connectTimeout;

  bool _connected = false;
  // Guards the disconnect path: an errored socket fires onError AND then
  // onDone, and manual close() must not trigger a reconnect. Without this a
  // single drop used to spawn two parallel reconnect loops.
  bool _disconnectHandled = false;

  WebSocketConnection({
    required super.onMessage,
    this.onDisconnect,
    super.requestTimeout,
    this.connectTimeout = const Duration(seconds: 10),
  });

  @override
  bool get isConnected => _connected;

  @override
  String get transportName => 'WebSocket';

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

    failPending(reason);

    onDisconnect?.call();
  }

  void _handleMessage(dynamic message) {
    if (message is Uint8List) {
      handleFrame(message);
    } else if (message is List<int>) {
      handleFrame(Uint8List.fromList(message));
    }
  }

  @override
  void sendFrame(Uint8List frame) => _channel!.sink.add(frame);

  @override
  Future<void> close() async {
    // Mark the disconnect as handled BEFORE tearing down the socket so a
    // trailing onDone can't trigger onDisconnect (and with it a reconnect).
    _disconnectHandled = true;
    _connected = false;
    failPending('Connection closed');
    await _subscription?.cancel();
    await _channel?.sink.close();
  }
}
