import 'dart:async';

import 'ws_message.dart';

class EventDispatcher {
  final Map<String, StreamController<WsMessage>> _listeners = {};

  void broadcast(WsMessage message) {
    final handle = message.handle;
    if (handle != null && _listeners.containsKey(handle)) {
      _listeners[handle]!.add(message);
    }
  }

  Stream<WsMessage> listen(String handle) {
    if (!_listeners.containsKey(handle)) {
      _listeners[handle] = StreamController<WsMessage>.broadcast();
    }
    return _listeners[handle]!.stream;
  }

  void unsubscribe(String handle) {
    _listeners[handle]?.close();
    _listeners.remove(handle);
  }
}
