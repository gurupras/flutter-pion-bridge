import 'dart:async';

import 'package:flutter/services.dart';

import 'event_dispatcher.dart';
import 'peer_connection.dart';
import 'reconnect.dart';
import 'types.dart';

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

  static Future<PionBridge> initialize({
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
    await pion._init();
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

  Future<void> _init() async {
    const platform = MethodChannel('io.filemingo.pionbridge');
    final result = await platform.invokeMethod('startServer');
    final port = result['port'] as int;
    final token = result['token'] as String;

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

    await _connection.connect('ws://127.0.0.1:$port/', token: token);
    await _sendInit();
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
      // Pass inner connection; after reconnect callers must create new PCs.
      _connection.currentConnection!,
      _dispatcher,
    );
  }

  Future<void> close() async {
    await _connection.close();
  }
}
