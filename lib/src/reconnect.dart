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
  // Single-flight guard: the underlying connection can report a disconnect
  // more than once (socket error fires onError AND onDone). Only one
  // reconnect chain may run at a time or every drop doubles the number of
  // live connections (and duplicates every event).
  bool _reconnecting = false;

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
    final conn = await _connectOnce();
    if (await _teardownIfClosed(conn)) {
      throw PionException('CONNECTION_LOST', 'Connection closed during connect',
          fatal: true);
    }
    _attempts = 0;
  }

  Future<WebSocketConnection> _connectOnce() async {
    final conn = WebSocketConnection(
      onMessage: onMessage,
      onDisconnect: _onDisconnect,
      requestTimeout: requestTimeout,
    );
    _conn = conn;
    await conn.connect(_url, token: _token);
    return conn;
  }

  /// If close() ran while [conn] was mid-connect, tear the fresh socket down
  /// and report true. Without this a reconnect attempt that resolves after
  /// close() would fire onReconnected post-close and leak a live socket
  /// (close() only closed the pre-connect shell of this object).
  Future<bool> _teardownIfClosed(WebSocketConnection conn) async {
    if (!_closed) return false;
    _reconnecting = false;
    if (identical(_conn, conn)) _conn = null;
    await conn.close();
    return true;
  }

  void _onDisconnect() {
    if (_closed || !autoReconnect) {
      onDisconnected?.call();
      return;
    }
    if (_reconnecting) return;
    _reconnecting = true;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final attempt = _attempts;
    if (maxAttempts != null && attempt >= maxAttempts!) {
      _reconnecting = false;
      onDisconnected?.call();
      return;
    }

    final delay = _backoffDelay(attempt);
    _attempts++;

    Future.delayed(delay, () async {
      if (_closed) {
        _reconnecting = false;
        return;
      }
      try {
        final conn = await _connectOnce();
        if (await _teardownIfClosed(conn)) return;
        _attempts = 0;
        _reconnecting = false;
        onReconnected?.call();
      } catch (_) {
        _scheduleReconnect();
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
