import 'dart:async';
import 'dart:math' as math;

import 'exception.dart';
import 'websocket_connection.dart';
import 'ws_message.dart';

/// Wraps [WebSocketConnection] with automatic exponential-backoff reconnection.
///
/// When the underlying connection drops (and [autoReconnect] is true), this
/// class schedules reconnect attempts with delays: 1s, 2s, 4s, 8s… up to
/// [maxDelay]. Events and requests are forwarded to the current connection.
class ReconnectingWebSocketConnection {
  WebSocketConnection? _conn;

  final void Function(WsMessage) onMessage;
  final void Function()? onReconnected;
  final void Function()? onDisconnected;

  final bool autoReconnect;
  final int? maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration requestTimeout;

  late String _url;
  late String _token;

  bool _closed = false;
  int _attempts = 0;

  ReconnectingWebSocketConnection({
    required this.onMessage,
    this.onReconnected,
    this.onDisconnected,
    this.autoReconnect = true,
    this.maxAttempts,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.requestTimeout = const Duration(seconds: 30),
  });

  bool get isConnected => _conn?.isConnected ?? false;

  /// The current underlying connection, or null if not connected.
  WebSocketConnection? get currentConnection => _conn;

  Future<void> connect(String url, {required String token}) async {
    _url = url;
    _token = token;
    await _connectOnce();
    _attempts = 0;
  }

  Future<void> _connectOnce() async {
    _conn = WebSocketConnection(
      onMessage: onMessage,
      onDisconnect: _onDisconnect,
      requestTimeout: requestTimeout,
    );
    await _conn!.connect(_url, token: _token);
  }

  void _onDisconnect() {
    if (_closed || !autoReconnect) {
      onDisconnected?.call();
      return;
    }

    final attempt = _attempts;
    if (maxAttempts != null && attempt >= maxAttempts!) {
      onDisconnected?.call();
      return;
    }

    final delay = _backoffDelay(attempt);
    _attempts++;

    Future.delayed(delay, () async {
      if (_closed) return;
      try {
        await _connectOnce();
        _attempts = 0;
        onReconnected?.call();
      } catch (_) {
        _onDisconnect();
      }
    });
  }

  /// Computes the backoff delay for a given attempt number.
  /// Exposed for testing.
  Duration backoffDelay(int attempt) => _backoffDelay(attempt);

  Duration _backoffDelay(int attempt) {
    final ms = baseDelay.inMilliseconds * math.pow(2, attempt).toInt();
    return Duration(milliseconds: ms.clamp(0, maxDelay.inMilliseconds));
  }

  Future<Map<String, dynamic>> request(
    String type,
    String? handle,
    Map<String, dynamic> data,
  ) {
    final conn = _conn;
    if (conn == null || !conn.isConnected) {
      return Future.error(
        PionException('CONNECTION_LOST', 'Not connected', fatal: true),
      );
    }
    return conn.request(type, handle, data);
  }

  Future<void> close() async {
    _closed = true;
    await _conn?.close();
    _conn = null;
  }
}
