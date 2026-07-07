import 'event_dispatcher.dart';
import 'websocket_connection.dart';
import 'ws_message.dart';

abstract class PionResource {
  final String handle;
  final WebSocketConnection connection;
  final EventDispatcher dispatcher;

  bool _disposed = false;

  PionResource(this.handle, this.connection, this.dispatcher);

  /// Whether local stream resources have been released.
  bool get isDisposed => _disposed;

  /// Releases this resource's local stream state (dispatcher subscription
  /// and derived stream controllers) WITHOUT issuing any RPC. Idempotent;
  /// returns false when already disposed so overrides can short-circuit.
  ///
  /// Subclasses override to close their own controllers and cascade to
  /// children (a PeerConnection disposes its DataChannels, mirroring the Go
  /// registry's cascade delete — the server side only needs the parent's
  /// resource:delete).
  bool disposeLocal() {
    if (_disposed) return false;
    _disposed = true;
    // Unsubscribing first means any deferred events pion emits for this
    // handle are silently dropped rather than routed to a StreamController
    // that is about to be torn down.
    dispatcher.unsubscribe(handle);
    return true;
  }

  Future<Map<String, dynamic>> request(
    String type,
    Map<String, dynamic> data, {
    Duration? timeout,
  }) {
    return connection.request(type, handle, data, timeout: timeout);
  }

  Stream<WsMessage> onEvent() {
    return dispatcher.listen(handle);
  }

  Future<void> close() async {
    // Local stream teardown first (see disposeLocal). The resource:delete RPC
    // uses a request-id Completer, not the dispatcher, so its response is
    // still delivered correctly.
    disposeLocal();
    await request('resource:delete', {}).catchError((_) => <String, dynamic>{});
  }
}
