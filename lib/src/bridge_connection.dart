import 'dart:async';
import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

import 'exception.dart';
import 'ws_message.dart';

/// One protocol session with the Go bridge, independent of how frames travel.
///
/// The protocol is msgpack frames in both directions: requests carry an id and
/// are answered by `<type>:ack` / `error` with the same id; events carry id 0.
/// Subclasses move frames — [WebSocketConnection] over a localhost WebSocket
/// to the sidecar, [FfiConnection] through dart:ffi into the in-process
/// library — and this class owns request/response correlation for both.
abstract class BridgeConnection {
  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final void Function(WsMessage) onMessage;
  final Duration requestTimeout;

  int _nextRequestId = 1;

  BridgeConnection({
    required this.onMessage,
    this.requestTimeout = const Duration(seconds: 30),
  });

  bool get isConnected;

  /// Hands one encoded frame to the transport. Only called while connected.
  void sendFrame(Uint8List frame);

  Future<void> close();

  /// Human-readable transport name used in errors.
  String get transportName;

  /// Feeds one inbound frame from the transport.
  void handleFrame(Uint8List bytes) {
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

  /// Fails every in-flight request with CONNECTION_LOST.
  void failPending(String reason) {
    final pending = Map.of(_pendingRequests);
    _pendingRequests.clear();
    for (final completer in pending.values) {
      completer.completeError(
        PionException('CONNECTION_LOST', reason, fatal: true),
      );
    }
  }

  PionException _notConnected() => PionException(
      'CONNECTION_LOST', '$transportName is not connected',
      fatal: true);

  /// Fire-and-forget send (id 0): no ack is awaited or correlated. Any ack
  /// the server broadcasts for id-0 sends is surfaced through [onMessage].
  void send(String type, String? handle, Map<String, dynamic> data) {
    if (!isConnected) throw _notConnected();
    final msg = WsMessage(type: type, id: 0, handle: handle, data: data);
    sendFrame(msgpack.serialize(msg.toMap()));
  }

  Future<Map<String, dynamic>> request(
    String type,
    String? handle,
    Map<String, dynamic> data, {
    Duration? timeout,
  }) async {
    if (!isConnected) throw _notConnected();

    final id = _nextRequestId++;
    final msg = WsMessage(
      type: type,
      id: id,
      handle: handle,
      data: data,
    );

    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    sendFrame(msgpack.serialize(msg.toMap()));

    return completer.future.timeout(
      timeout ?? requestTimeout,
      onTimeout: () {
        _pendingRequests.remove(id);
        throw PionException('OPERATION_TIMEOUT', 'Request timed out');
      },
    );
  }
}
