import 'dart:async';

/// A broadcast stream that buffers events added before its FIRST listener
/// attaches and replays them, in order, once it does. After the first
/// listener, standard broadcast semantics apply (later listeners see live
/// events only; events with no listeners are dropped).
///
/// Resources ([PionDataChannel], [PionPeerConnection]) fan their handle's
/// event stream out into one of these per event type. This is what makes
/// event delivery independent of the order the app subscribes its streams:
/// a `dataChannelOpen` that arrives before the app calls `onOpen.listen`
/// waits in the `onOpen` buffer regardless of which other streams were
/// subscribed first. (The old design replayed the whole per-handle buffer
/// into ONE shared controller on its first leaf subscription, so whichever
/// of the five derived streams was listened first silently consumed every
/// other stream's buffered events.)
class BufferedBroadcast<T> {
  /// Cap on buffered events. Matches the dispatcher's per-handle cap: past
  /// this, the consumer is missing-in-action and unbounded buffering would
  /// just turn a bug into a leak.
  static const int maxBuffered = 128;

  final _controller = StreamController<T>.broadcast();
  List<T>? _pending = <T>[];

  BufferedBroadcast() {
    _controller.onListen = () {
      _controller.onListen = null;
      final pending = _pending;
      _pending = null;
      if (pending != null) {
        for (final event in pending) {
          _controller.add(event);
        }
      }
    };
  }

  void add(T event) {
    final pending = _pending;
    if (pending != null) {
      if (pending.length < maxBuffered) pending.add(event);
    } else if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  Stream<T> get stream => _controller.stream;

  void close() {
    _pending = null;
    _controller.onListen = null;
    _controller.close();
  }
}
