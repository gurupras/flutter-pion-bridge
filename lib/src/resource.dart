import 'event_dispatcher.dart';
import 'websocket_connection.dart';
import 'ws_message.dart';

abstract class PionResource {
  final String handle;
  final WebSocketConnection connection;
  final EventDispatcher dispatcher;

  PionResource(this.handle, this.connection, this.dispatcher);

  Future<Map<String, dynamic>> request(
    String type,
    Map<String, dynamic> data,
  ) {
    return connection.request(type, handle, data);
  }

  Stream<WsMessage> onEvent() {
    return dispatcher.listen(handle);
  }

  Future<void> close() async {
    // Unsubscribe from the event dispatcher first so that any deferred events
    // pion emits for this handle (e.g. ICE candidates fired by a sibling
    // connection closing) are silently dropped rather than routed to a
    // StreamController that is about to be torn down.  The resource:delete RPC
    // uses a request-id Completer, not the dispatcher, so its response is
    // still delivered correctly.
    dispatcher.unsubscribe(handle);
    await request('resource:delete', {}).catchError((_) {});
  }
}
