import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'event_dispatcher.dart';
import 'peer_connection.dart';
import 'types.dart';
import 'websocket_connection.dart';

/// Manages the connection lifecycle, including exponential-backoff reconnection.
class PionBridge {
  late WebSocketConnection _connection;
  late EventDispatcher _dispatcher;

  // Server address — stored so reconnect can re-use them
  late String _wsUrl;
  late String _token;

  bool _closed = false;

  /// Called each time the WebSocket is successfully (re)connected.
  /// Callers should use this to re-create their [PionPeerConnection] objects
  /// because all server-side WebRTC state is lost on reconnect.
  final void Function()? onReconnected;

  /// Called when the connection is permanently lost after all retry attempts
  /// or when [close] is called.
  final void Function()? onDisconnected;

  /// Maximum number of reconnect attempts (null = unlimited).
  final int? maxReconnectAttempts;

  int _reconnectAttempts = 0;

  static const Duration _baseDelay = Duration(seconds: 1);
  static const Duration _maxDelay = Duration(seconds: 30);

  PionBridge._({
    this.onReconnected,
    this.onDisconnected,
    this.maxReconnectAttempts,
  });

  static Future<PionBridge> initialize({
    void Function()? onReconnected,
    void Function()? onDisconnected,
    int? maxReconnectAttempts,
  }) async {
    final pion = PionBridge._(
      onReconnected: onReconnected,
      onDisconnected: onDisconnected,
      maxReconnectAttempts: maxReconnectAttempts,
    );
    await pion._init();
    return pion;
  }

  Future<void> _init() async {
    const platform = MethodChannel('io.filemingo.pionbridge');
    final result = await platform.invokeMethod('startServer');
    final port = result['port'] as int;
    _token = result['token'] as String;
    _wsUrl = 'ws://127.0.0.1:$port/';

    _dispatcher = EventDispatcher();
    await _connect();
  }

  Future<void> _connect() async {
    _connection = WebSocketConnection(
      onMessage: _dispatcher.broadcast,
      onDisconnect: _onDisconnect,
    );
    await _connection.connect(_wsUrl, token: _token);
    _reconnectAttempts = 0;
  }

  void _onDisconnect() {
    if (_closed) {
      onDisconnected?.call();
      return;
    }

    final attempt = _reconnectAttempts;
    if (maxReconnectAttempts != null && attempt >= maxReconnectAttempts!) {
      onDisconnected?.call();
      return;
    }

    final delay = _backoffDelay(attempt);
    _reconnectAttempts++;

    Future.delayed(delay, () async {
      if (_closed) return;
      try {
        await _connect();
        onReconnected?.call();
      } catch (_) {
        // _connect failed — treat as another disconnect
        _onDisconnect();
      }
    });
  }

  static Duration _backoffDelay(int attempt) {
    final ms = _baseDelay.inMilliseconds * math.pow(2, attempt).toInt();
    return Duration(milliseconds: ms.clamp(0, _maxDelay.inMilliseconds));
  }

  bool get isConnected => _connection.isConnected;

  Future<PionPeerConnection> createPeerConnection({
    List<IceServer>? iceServers,
    String bundlePolicy = 'balanced',
    String rtcpMuxPolicy = 'require',
  }) async {
    final response = await _connection.request('pc:create', null, {
      'ice_servers': iceServers?.map((s) => s.toMap()).toList() ?? [],
      'bundle_policy': bundlePolicy,
      'rtcp_mux_policy': rtcpMuxPolicy,
    });

    return PionPeerConnection(
      response['handle'] as String,
      _connection,
      _dispatcher,
    );
  }

  Future<void> close() async {
    _closed = true;
    await _connection.close();
  }
}
