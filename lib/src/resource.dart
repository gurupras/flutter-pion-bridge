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
    await request('resource:delete', {});
    dispatcher.unsubscribe(handle);
  }
}
