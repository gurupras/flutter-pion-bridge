// Regression tests for the 2026-07-06 audit findings (Dart side). Each test
// targets one verified defect and fails on the pre-fix code:
//
//  1. Buffered pre-subscription events were replayed only into the shared
//     broadcast controller on its FIRST leaf subscription; a PionDataChannel
//     derives five filtered streams from that one controller, so whichever
//     leaf was listened first drained the whole buffer and later-subscribed
//     leaves (e.g. onOpen after onMessage) silently missed their events.
//  2. Worse: events arriving AFTER wrapper construction but BEFORE the app's
//     first leaf subscription were added to a listener-less broadcast
//     controller and dropped entirely.
//  3. close() during an in-flight reconnect attempt let the attempt complete:
//     onReconnected fired after close and the fresh socket leaked.
//  4. EventDispatcher._closedHandles grew by one permanent string per closed
//     resource for the bridge's lifetime.
//  5. Closing a PionPeerConnection released only its own handle; child
//     DataChannel controllers leaked in the dispatcher until closeAll().

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/event_dispatcher.dart' as pion;
import 'package:pion_bridge/src/peer_connection.dart';
import 'package:pion_bridge/src/reconnect.dart';
import 'package:pion_bridge/src/websocket_connection.dart';
import 'package:pion_bridge/src/ws_message.dart';

/// A local WebSocket server whose upgrade step can be gated on a Completer,
/// so a test can deterministically hold a client connect attempt in flight.
class _GatedWsServer {
  late HttpServer _server;
  final List<WebSocket> sockets = [];
  int closedSockets = 0;
  int get connectionCount => sockets.length;

  /// When set, incoming upgrade requests wait on it before completing.
  Completer<void>? gate;

  /// Completed each time an upgrade request ARRIVES (before the gate).
  void Function()? onRequest;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      onRequest?.call();
      final g = gate;
      if (g != null) await g.future;
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.done.then((_) => closedSockets++, onError: (_) => closedSockets++);
      ws.listen((_) {}, onError: (_) {}, cancelOnError: true);
    });
    return 'ws://127.0.0.1:${_server.port}/';
  }

  Future<void> stop() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await _server.close(force: true);
  }
}

WsMessage _event(String type, String handle,
        [Map<String, dynamic> data = const {}]) =>
    WsMessage(type: type, id: 0, handle: handle, data: Map.of(data));

void main() {
  group('per-type buffered event delivery', () {
    test(
        'buffered dataChannelOpen reaches onOpen even when onMessage '
        'subscribes first', () async {
      final dispatcher = pion.EventDispatcher();
      final conn = WebSocketConnection(onMessage: (_) {});

      // Fast loopback: Go emits open + first message before the app has the
      // wrapper (both events buffered in the dispatcher under the handle).
      dispatcher.broadcast(_event('event:dataChannelOpen', 'dc1'));
      dispatcher.broadcast(_event('event:dataChannelMessage', 'dc1', {
        'data': Uint8List.fromList([1, 2, 3]),
        'is_binary': true,
      }));

      final dc = PionDataChannel('dc1', conn, dispatcher);

      final messages = <int>[];
      final msgSub = dc.onMessage.listen((m) => messages.add(m.bytes.length));
      addTearDown(msgSub.cancel);

      // Subscribing onOpen AFTER onMessage must still deliver the buffered
      // open event — pre-fix the first leaf subscription drained the whole
      // shared buffer and the open was gone.
      var opened = 0;
      final openSub = dc.onOpen.listen((_) => opened++);
      addTearDown(openSub.cancel);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(opened, 1,
          reason: 'the buffered dataChannelOpen must reach a later-subscribed '
              'onOpen stream');
      expect(messages, [3],
          reason: 'the buffered message must reach onMessage exactly once');
    });

    test(
        'events arriving after wrapper construction but before any leaf '
        'subscription are not lost', () async {
      final dispatcher = pion.EventDispatcher();
      final conn = WebSocketConnection(onMessage: (_) {});

      final dc = PionDataChannel('dc1', conn, dispatcher);

      // Wrapper exists (controller created) but the app has not subscribed
      // any stream yet — pre-fix these were added to a listener-less
      // broadcast controller and dropped forever.
      dispatcher.broadcast(_event('event:dataChannelOpen', 'dc1'));
      dispatcher.broadcast(_event('event:dataChannelMessage', 'dc1', {
        'data': Uint8List.fromList([9]),
        'is_binary': true,
      }));
      await Future<void>.delayed(Duration.zero);

      var opened = 0;
      final messages = <int>[];
      final openSub = dc.onOpen.listen((_) => opened++);
      final msgSub = dc.onMessage.listen((m) => messages.add(m.bytes.length));
      addTearDown(openSub.cancel);
      addTearDown(msgSub.cancel);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(opened, 1,
          reason: 'open emitted before the app subscribed must be delivered');
      expect(messages, [1],
          reason: 'message emitted before the app subscribed must be '
              'delivered');
    });
  });

  group('reconnect vs close race', () {
    test(
        'close() during an in-flight reconnect attempt does not fire '
        'onReconnected or leak the fresh socket', () async {
      final server = _GatedWsServer();
      final url = await server.start();
      addTearDown(server.stop);

      var reconnected = 0;
      final conn = ReconnectingWebSocketConnection(
        onMessage: (_) {},
        baseDelay: const Duration(milliseconds: 50),
        onReconnected: () => reconnected++,
      );
      await conn.connect(url, token: 't');
      expect(server.connectionCount, 1);

      // Hold the next upgrade so the reconnect attempt stays in flight.
      final attemptArrived = Completer<void>();
      server.gate = Completer<void>();
      server.onRequest = () {
        if (!attemptArrived.isCompleted) attemptArrived.complete();
      };

      // Drop the connection → a reconnect is scheduled and dialed.
      conn.currentConnection!.debugHandleDisconnect('drop');
      await attemptArrived.future;

      // Close while the attempt is suspended inside connect().
      await conn.close();

      // Let the held upgrade finish; the attempt's connect() now resolves.
      server.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(reconnected, 0,
          reason: 'onReconnected must not fire after close()');
      expect(conn.isConnected, isFalse,
          reason: 'a reconnect attempt resolving after close() must not '
              'leave the wrapper connected');
      expect(conn.currentConnection, isNull,
          reason: 'no live connection may be retained after close()');
    });
  });

  group('dispatcher leak bounds', () {
    test('_closedHandles does not grow without bound', () {
      final dispatcher = pion.EventDispatcher();
      for (var i = 0; i < 10000; i++) {
        dispatcher.listen('handle-$i');
        dispatcher.unsubscribe('handle-$i');
      }
      expect(dispatcher.debugClosedHandleCount, lessThanOrEqualTo(4096),
          reason: 'closed-handle tombstones must be bounded; one permanent '
              'entry per closed resource leaks for the bridge lifetime');
    });

    test('closing a PeerConnection releases its child DataChannel streams',
        () async {
      final dispatcher = pion.EventDispatcher();
      final conn = WebSocketConnection(onMessage: (_) {});
      final pc = PionPeerConnection('pc1', conn, dispatcher);

      // A remote DataChannel arrives and the app obtains its wrapper.
      final dcArrived = Completer<PionDataChannel>();
      final sub = pc.onDataChannel.listen((dc) {
        if (!dcArrived.isCompleted) dcArrived.complete(dc);
      });
      addTearDown(sub.cancel);
      dispatcher.broadcast(_event('event:dataChannel', 'pc1', {
        'dc_handle': 'dc1',
        'label': 'remote',
      }));
      final dc = await dcArrived.future;
      // Touch a stream so the child's controller is definitely live.
      final msgSub = dc.onMessage.listen((_) {});
      addTearDown(msgSub.cancel);
      await Future<void>.delayed(Duration.zero);

      // Closing the PC (RPC fails — not connected — and is swallowed) must
      // release the child DC's dispatcher entry too, mirroring the Go
      // registry's cascade.
      await pc.close();
      await Future<void>.delayed(Duration.zero);

      expect(dispatcher.debugListenerCount, 0,
          reason: 'PC close must release child DataChannel controllers; '
              'pre-fix they leaked until PionBridge.close()');
    });
  });
}
