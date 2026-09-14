import 'dart:async';

import 'package:flutter/services.dart';

import 'bridge_connection.dart';
import 'event_dispatcher.dart';
import 'exception.dart';
import 'ffi_connection.dart';
import 'peer_connection.dart';
import 'reconnect.dart';
import 'types.dart';

/// How the Dart side reaches the Go bridge.
enum PionBridgeMode {
  /// The Go server listens on a localhost WebSocket: a sidecar process on
  /// desktop, the gomobile in-process server on Android/iOS. Supports
  /// [PionBridge.startServer] / [PionBridge.connectExisting] and reconnects.
  websocket,

  /// The Go bridge is a shared library loaded into this process with
  /// dart:ffi; frames are passed by function call. No sidecar, no socket, no
  /// token, and it can be initialized from any isolate. Desktop only
  /// (currently bundled on Linux). There is nothing to reconnect to: the
  /// session lives until [PionBridge.close].
  shared,
}

class PionBridge {
  // Exactly one of these is set, depending on the mode.
  ReconnectingWebSocketConnection? _ws;
  FfiConnection? _ffi;
  late EventDispatcher _dispatcher;
  PionSettingsEngine? _settingsEngine;
  PionMediaEngine? _mediaEngine;

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

  /// Starts the Go bridge and connects to it.
  ///
  /// [mode] defaults to [PionBridgeMode.websocket], which is how the bridge
  /// has always worked: it must be called from the root isolate (it invokes
  /// a [MethodChannel] to spawn the native server). To drive pion from a
  /// worker isolate in that mode, use [startServer] on the root isolate, ship
  /// the returned [PionServerEndpoint] to the worker, and call
  /// [connectExisting] from the worker.
  ///
  /// With [PionBridgeMode.shared] the bridge is loaded in-process from
  /// [sharedLibraryPath] (default: where the plugin bundles it) and this may
  /// be called from any isolate. [onReconnected] and [maxReconnectAttempts]
  /// do not apply; [onDisconnected] fires when the bridge is closed.
  static Future<PionBridge> initialize({
    PionBridgeMode mode = PionBridgeMode.websocket,
    String? sharedLibraryPath,
    PionSettingsEngine? settingsEngine,
    PionMediaEngine? mediaEngine,
    void Function()? onReconnected,
    void Function()? onDisconnected,
    int? maxReconnectAttempts,
  }) async {
    if (mode == PionBridgeMode.shared) {
      final pion = PionBridge._(onDisconnected: onDisconnected);
      pion._settingsEngine = settingsEngine;
      pion._mediaEngine = mediaEngine;
      pion._dispatcher = EventDispatcher();
      pion._ffi = FfiConnection.open(
        onMessage: pion._dispatcher.broadcast,
        libraryPath: sharedLibraryPath,
      );
      await pion._sendInit();
      return pion;
    }
    final endpoint = await startServer();
    return connectExisting(
      endpoint,
      settingsEngine: settingsEngine,
      mediaEngine: mediaEngine,
      onReconnected: onReconnected,
      onDisconnected: onDisconnected,
      maxReconnectAttempts: maxReconnectAttempts,
    );
  }

  /// Starts the native pion bridge server via the platform channel and returns
  /// its WebSocket endpoint.
  ///
  /// **Must be called from the root isolate** — invokes the
  /// `io.pion_bridge.bridge` [MethodChannel].  If the host app starts the
  /// server through a different mechanism (e.g. FFI into a combined native
  /// library), obtain the [PionServerEndpoint] directly and call
  /// [connectExisting] instead of this method.
  ///
  /// The server lives for the lifetime of the process (a second call is a
  /// no-op-ish reset on the native side).  Closing a [PionBridge] only closes
  /// its own WebSocket — other [PionBridge] instances on other isolates remain
  /// connected.
  static Future<PionServerEndpoint> startServer() async {
    const platform = MethodChannel('io.pion_bridge.bridge');
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
    PionMediaEngine? mediaEngine,
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
    pion._mediaEngine = mediaEngine;
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
    final me = _mediaEngine;
    if (me != null) data['media_engine'] = me.toMap();
    await _requireConnection().request('init', null, data);
  }

  Future<void> _connect(PionServerEndpoint endpoint) async {
    _dispatcher = EventDispatcher();
    final ws = _ws = ReconnectingWebSocketConnection(
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

    await ws.connect(
      'ws://127.0.0.1:${endpoint.port}/',
      token: endpoint.token,
    );
    await _sendInit();
  }

  /// The mode this bridge was initialized with.
  PionBridgeMode get mode =>
      _ffi != null ? PionBridgeMode.shared : PionBridgeMode.websocket;

  bool get isConnected => _ffi?.isConnected ?? _ws?.isConnected ?? false;

  /// The live session: the FFI session, or the current WebSocket (which
  /// changes across reconnects).
  BridgeConnection _requireConnection() {
    final conn = _ffi ?? _ws?.currentConnection;
    if (conn == null || !conn.isConnected) {
      throw PionException('CONNECTION_LOST', 'Not connected', fatal: true);
    }
    return conn;
  }

  /// Creates a PeerConnection.
  ///
  /// [settingsEngine] overrides the session's settings for THIS connection
  /// only (pion applies a SettingEngine per API, and the bridge caches one API
  /// per distinct payload). Use it to mix configurations in one bridge, e.g. a
  /// connection with [PionSettingsEngine.detachDataChannels] for bulk transfer
  /// beside a default one for latency-sensitive channels. Data channels follow
  /// the connection they belong to.
  ///
  /// [mediaEngine] likewise overrides the session's codecs for this
  /// connection; overriding one of the two keeps the session's other.
  Future<PionPeerConnection> createPeerConnection({
    PionSettingsEngine? settingsEngine,
    PionMediaEngine? mediaEngine,
    List<IceServer>? iceServers,
    String bundlePolicy = 'balanced',
    String rtcpMuxPolicy = 'require',
    // 'relay' forces ICE to use ONLY relay (TURN) candidates; 'all' (default)
    // keeps host/srflx/relay. See handler.go handlePCCreate.
    String iceTransportPolicy = 'all',
    void Function(String)? onLog,
  }) async {
    final connection = _requireConnection();
    final perPC = settingsEngine?.toMap();
    final response = await connection.request('pc:create', null, {
      if (perPC != null && perPC.isNotEmpty) 'settings_engine': perPC,
      if (mediaEngine != null) 'media_engine': mediaEngine.toMap(),
      'ice_servers': iceServers?.map((s) => s.toMap()).toList() ?? [],
      'bundle_policy': bundlePolicy,
      'rtcp_mux_policy': rtcpMuxPolicy,
      'ice_transport_policy': iceTransportPolicy,
    });

    return PionPeerConnection(
      response['handle'] as String,
      // Pass inner connection; after reconnect callers must create new PCs.
      connection,
      _dispatcher,
      onLog: onLog,
    );
  }

  Future<void> close() async {
    final ffi = _ffi;
    if (ffi != null) {
      final wasOpen = ffi.isConnected;
      await ffi.close();
      _dispatcher.closeAll();
      if (wasOpen) onDisconnected?.call();
      return;
    }
    await _ws?.close();
    _dispatcher.closeAll();
  }
}
