import 'dart:async';

import 'package:meta/meta.dart';

import 'ws_message.dart';

class EventDispatcher {
  final Map<String, StreamController<WsMessage>> _listeners = {};

  // Events that arrive before anyone subscribes to a handle. On a fast
  // loopback Go can emit dataChannelOpen (or the first message) before the
  // app's onDataChannel mapper has constructed the child streams; dropping
  // those events loses them permanently. Buffered events are replayed to the
  // first subscriber, in order.
  final Map<String, List<WsMessage>> _buffered = {};

  // Handles explicitly unsubscribed (resource closed). Late events for these
  // must be dropped, not re-buffered forever.
  final Set<String> _closedHandles = {};

  bool _closed = false;

  /// Cap on buffered events per not-yet-subscribed handle. Beyond this the
  /// oldest semantics don't matter — something is wrong on the consumer side
  /// and unbounded buffering would just turn a bug into a leak.
  static const int maxBufferedPerHandle = 128;

  /// Cap on closed-handle tombstones. Handles are one-shot UUIDs, so the set
  /// would otherwise grow by one permanent string per closed resource for the
  /// bridge's lifetime. The tombstone only needs to outlive stragglers from
  /// pion's teardown; evicting the oldest entry means a very late event for a
  /// long-closed handle re-buffers (capped at [maxBufferedPerHandle]) instead
  /// of being dropped — an acceptable trade for a bounded footprint.
  static const int maxClosedHandles = 4096;

  /// Number of live per-handle controllers. Test hook for leak assertions.
  @visibleForTesting
  int get debugListenerCount => _listeners.length;

  /// Size of the closed-handle tombstone set. Test hook for leak assertions.
  @visibleForTesting
  int get debugClosedHandleCount => _closedHandles.length;

  void broadcast(WsMessage message) {
    if (_closed) return;
    final handle = message.handle;
    if (handle == null) return;

    final controller = _listeners[handle];
    if (controller != null) {
      controller.add(message);
      return;
    }
    if (_closedHandles.contains(handle)) return;

    final buffer = _buffered.putIfAbsent(handle, () => []);
    if (buffer.length < maxBufferedPerHandle) {
      buffer.add(message);
    }
  }

  Stream<WsMessage> listen(String handle) {
    final existing = _listeners[handle];
    if (existing != null) return existing.stream;

    final controller = StreamController<WsMessage>.broadcast();
    _listeners[handle] = controller;
    _closedHandles.remove(handle);

    final buffered = _buffered.remove(handle);
    if (buffered != null && buffered.isNotEmpty) {
      // Replay once the first listener attaches; a broadcast controller
      // discards events added while it has no listeners.
      controller.onListen = () {
        controller.onListen = null;
        for (final msg in buffered) {
          controller.add(msg);
        }
      };
    }
    return controller.stream;
  }

  void unsubscribe(String handle) {
    _buffered.remove(handle);
    _closedHandles.add(handle);
    if (_closedHandles.length > maxClosedHandles) {
      // Default Set iteration order is insertion order: evict the oldest.
      _closedHandles.remove(_closedHandles.first);
    }
    final controller = _listeners.remove(handle);
    controller?.close();
  }

  /// Closes every per-handle stream and drops all buffered events. Called by
  /// [PionBridge.close] so long-lived apps don't leak one controller per
  /// abandoned handle.
  void closeAll() {
    _closed = true;
    for (final controller in _listeners.values) {
      controller.close();
    }
    _listeners.clear();
    _buffered.clear();
    _closedHandles.clear();
  }
}
