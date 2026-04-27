import 'dart:async';

import 'package:flutter/services.dart';

import 'event_dispatcher.dart';
import 'peer_connection.dart';
import 'reconnect.dart';
import 'types.dart';

/// Connection details for an already-running pion bridge server.
///
/// Returned by [PionBridge.startServer] (which must run on the root isolate)
/// and consumed by [PionBridge.connectExisting] (which can run on any
/// isolate). Send across isolate boundaries via `SendPort.send`.
class PionServerEndpoint {
  final int port;
  final String token;

  const PionServerEndpoint({required this.port, required this.token});

  Map<String, dynamic> toMap() => {'port': port, 'token': token};

  factory PionServerEndpoint.fromMap(Map<dynamic, dynamic> map) =>
      PionServerEndpoint(
        port: map['port'] as int,
        token: map['token'] as String,
      );
}

class PionBridge {
  late ReconnectingWebSocketConnection _connection;
  late EventDispatcher _dispatcher;
  PionSettingsEngine? _settingsEngine;

  /// Called each time the WebSocket successfully reconnects.
  /// All prior [PionPeerConnection] handles are invalid after reconnect;
  /// callers should create new ones.
  final void Function()? onReconnected;

  /// Called when the connection is permanently closed.
  final void Function()? onDisconnected;

  /// Maximum reconnect attempts (null = unlimited).
  final int? maxReconnectAttempts;

  PionBridge._({
    this.onReconnected,
    this.onDisconnected,
    this.maxReconnectAttempts,
  });

  /// Starts the in-process Go bridge server and connects to it.
  ///
  /// Must be called from the root isolate — invokes a [MethodChannel] to
  /// spawn the native server. To drive pion from a worker isolate, use
  /// [startServer] on the root isolate, ship the returned [PionServerEndpoint]
  /// to the worker, and call [connectExisting] from the worker.
  static Future<PionBridge> initialize({
    PionSettingsEngine? settingsEngine,
    void Function()? onReconnected,
    void Function()? onDisconnected,
    int? maxReconnectAttempts,
  }) async {
    final endpoint = await startServer();
    return connectExisting(
      endpoint,
      settingsEngine: settingsEngine,
      onReconnected: onReconnected,
      onDisconnected: onDisconnected,
      maxReconnectAttempts: maxReconnectAttempts,
    );
  }

  /// Starts the native pion bridge server and returns its WebSocket endpoint.
  ///
  /// **Must be called from the root isolate** — this invokes a
  /// [MethodChannel], which is only available there. The returned
  /// [PionServerEndpoint] can be sent to worker isolates, which can then call
  /// [connectExisting] to attach without going through the platform channel.
  ///
  /// The server lives for the lifetime of the process (a second call is a
  /// no-op-ish reset on the native side). Closing a [PionBridge] only closes
  /// its own WebSocket — other [PionBridge] instances on other isolates
  /// remain connected.
  static Future<PionServerEndpoint> startServer() async {
    const platform = MethodChannel('io.filemingo.pionbridge');
    final result = await platform.invokeMethod('startServer');
    return PionServerEndpoint(
      port: result['port'] as int,
      token: result['token'] as String,
    );
  }

  /// Connects to an already-running pion bridge server.
  ///
  /// Safe to call from **any isolate** — does not touch [MethodChannel].
  /// Obtain [endpoint] by calling [startServer] on the root isolate and
  /// shipping the result to this isolate (e.g. via a [SendPort]).
  ///
  /// Each [PionBridge] gets its own WebSocket session, request-id stream,
  /// and event dispatcher; resources created here are owned by this isolate
  /// and not visible to other isolates' bridges.
  static Future<PionBridge> connectExisting(
    PionServerEndpoint endpoint, {
    PionSettingsEngine? settingsEngine,
    void Function()? onReconnected,
    void Function()? onDisconnected,
    int? maxReconnectAttempts,
  }) async {
    final pion = PionBridge._(
      onReconnected: onReconnected,
      onDisconnected: onDisconnected,
      maxReconnectAttempts: maxReconnectAttempts,
    );
    pion._settingsEngine = settingsEngine;
    await pion._connect(endpoint);
    return pion;
  }

  Future<void> _sendInit() async {
    final data = <String, dynamic>{};
    final se = _settingsEngine;
    if (se != null) {
      final seMap = se.toMap();
      if (seMap.isNotEmpty) data['settings_engine'] = seMap;
    }
    await _connection.request('init', null, data);
  }

  Future<void> _connect(PionServerEndpoint endpoint) async {
    _dispatcher = EventDispatcher();
    _connection = ReconnectingWebSocketConnection(
      onMessage: _dispatcher.broadcast,
      onReconnected: () {
        // Re-send init on reconnect so the new Go Handler gets the same
        // SettingEngine config. Fire-and-forget; then notify the caller.
        _sendInit().then(
          (_) => onReconnected?.call(),
          onError: (_) => onReconnected?.call(),
        );
      },
      onDisconnected: onDisconnected,
      maxAttempts: maxReconnectAttempts,
    );

    await _connection.connect(
      'ws://127.0.0.1:${endpoint.port}/',
      token: endpoint.token,
    );
    await _sendInit();
  }

  bool get isConnected => _connection.isConnected;

  Future<PionPeerConnection> createPeerConnection({
    List<IceServer>? iceServers,
    String bundlePolicy = 'balanced',
    String rtcpMuxPolicy = 'require',
    void Function(String)? onLog,
  }) async {
    final response = await _connection.request('pc:create', null, {
      'ice_servers': iceServers?.map((s) => s.toMap()).toList() ?? [],
      'bundle_policy': bundlePolicy,
      'rtcp_mux_policy': rtcpMuxPolicy,
    });

    return PionPeerConnection(
      response['handle'] as String,
      // Pass inner connection; after reconnect callers must create new PCs.
      _connection.currentConnection!,
      _dispatcher,
      onLog: onLog,
    );
  }

  Future<void> close() async {
    await _connection.close();
  }
}
