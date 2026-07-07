// Regression tests for the 2026-07 audit fixes (Dart side). Each test
// targets one verified defect and fails on the pre-fix code:
//
//  1. double disconnect (onError + onDone) used to fire onDisconnect twice,
//     spawning parallel reconnect loops that leaked sockets and duplicated
//     every event;
//  2. EventDispatcher dropped events for handles nobody had subscribed to
//     yet (fast loopback loses dataChannelOpen/first message);
//  3. EventDispatcher/PionBridge had no dispose path for controllers;
//  4. close() left in-flight requests hanging until the 30s timeout;
//  5. a malformed event:dc:error killed the stream with an unhandled cast
//     error;
//  6. DataChannelMessage.text threw on non-UTF8 payloads;
//  7. sendBinary had no per-call timeout override for slow drains.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/event_dispatcher.dart' as pion;
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/reconnect.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';
import 'package:pion_bridge/src/ws_message.dart';

/// A minimal local WebSocket server that accepts connections and counts them.
/// It never sends anything, so requests against it stay pending forever.
class _SilentWsServer {
  late HttpServer _server;
  final List<WebSocket> sockets = [];
  int get connectionCount => sockets.length;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
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

void main() {
  group('disconnect handling', () {
    test('onDisconnect fires exactly once for error-then-done double fire',
        () async {
      final server = _SilentWsServer();
      final url = await server.start();
      addTearDown(server.stop);

      var disconnects = 0;
      final conn = WebSocketConnection(
        onMessage: (_) {},
        onDisconnect: () => disconnects++,
      );
      await conn.connect(url, token: 't');

      // A socket error produces onError AND then onDone on the stream; the
      // handler must be idempotent.
      conn.debugHandleDisconnect('error');
      conn.debugHandleDisconnect('done');

      expect(disconnects, 1,
          reason: 'double disconnect must not fire onDisconnect twice '
              '(it used to spawn parallel reconnect loops)');
    });

    test('double disconnect schedules exactly one reconnect', () async {
      final server = _SilentWsServer();
      final url = await server.start();
      addTearDown(server.stop);

      final conn = ReconnectingWebSocketConnection(
        onMessage: (_) {},
        baseDelay: const Duration(milliseconds: 50),
      );
      await conn.connect(url, token: 't');
      addTearDown(conn.close);
      expect(server.connectionCount, 1);

      // Simulate the error-then-done double fire on the underlying socket.
      conn.currentConnection!.debugHandleDisconnect('error');
      conn.currentConnection!.debugHandleDisconnect('done');

      // Give ample time for any scheduled reconnects (50ms base delay).
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(server.connectionCount, 2,
          reason: 'one drop must produce exactly one reconnect, not a storm');
    });

    test('close() fails pending requests promptly instead of leaving them '
        'hanging until the request timeout', () async {
      final server = _SilentWsServer();
      final url = await server.start();
      addTearDown(server.stop);

      final conn = WebSocketConnection(onMessage: (_) {});
      await conn.connect(url, token: 't');

      final pending = conn.request('init', null, {});
      // Swallow the eventual error; we only care WHEN it completes.
      final settled = pending.then((_) => true, onError: (_) => true);

      await conn.close();

      final result = await settled.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => false,
      );
      expect(result, isTrue,
          reason: 'pending requests must settle when the connection closes, '
              'not hang until the 30s timeout');
    });
  });

  group('EventDispatcher', () {
    test('buffers events that arrive before the first subscriber', () async {
      final dispatcher = pion.EventDispatcher();

      // Go can deliver dataChannelOpen before the app subscribes (fast
      // loopback). These events used to be dropped silently.
      dispatcher.broadcast(
          WsMessage(type: 'event:dataChannelOpen', id: 0, handle: 'h1', data: {}));
      dispatcher.broadcast(WsMessage(
          type: 'event:dataChannelMessage',
          id: 0,
          handle: 'h1',
          data: {'data': 'hello'}));

      final received = <String>[];
      final sub = dispatcher.listen('h1').listen((m) => received.add(m.type));
      addTearDown(sub.cancel);

      await Future<void>.delayed(Duration.zero);
      expect(received, ['event:dataChannelOpen', 'event:dataChannelMessage'],
          reason: 'pre-subscription events must be delivered, in order');

      // Live events keep flowing after the replay.
      dispatcher.broadcast(WsMessage(
          type: 'event:dataChannelClose', id: 0, handle: 'h1', data: {}));
      await Future<void>.delayed(Duration.zero);
      expect(received.last, 'event:dataChannelClose');
    });

    test('does not re-buffer events for an unsubscribed (closed) handle',
        () async {
      final dispatcher = pion.EventDispatcher();
      final sub = dispatcher.listen('h1').listen((_) {});
      dispatcher.unsubscribe('h1');
      await sub.cancel();

      // Late events for a deleted resource must be dropped, not buffered
      // forever.
      dispatcher.broadcast(
          WsMessage(type: 'event:late', id: 0, handle: 'h1', data: {}));

      final received = <WsMessage>[];
      final sub2 = dispatcher.listen('h1').listen(received.add);
      addTearDown(sub2.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty,
          reason: 'events for closed handles must not be replayed to a new '
              'subscriber');
    });

    test('closeAll closes every per-handle stream', () async {
      final dispatcher = pion.EventDispatcher();
      var done1 = false, done2 = false;
      final s1 = dispatcher.listen('a').listen((_) {}, onDone: () => done1 = true);
      final s2 = dispatcher.listen('b').listen((_) {}, onDone: () => done2 = true);
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);

      dispatcher.closeAll();
      await Future<void>.delayed(Duration.zero);

      expect(done1 && done2, isTrue,
          reason: 'closeAll must complete all per-handle streams so '
              'PionBridge.close() does not leak controllers');
      // And further broadcasts must be safely ignored.
      dispatcher.broadcast(
          WsMessage(type: 'event:x', id: 0, handle: 'a', data: {}));
    });
  });

  group('lenient event parsing', () {
    test('malformed event:dc:error does not kill the onError stream',
        () async {
      final dispatcher = pion.EventDispatcher();
      final conn = WebSocketConnection(onMessage: (_) {});
      final dc = PionDataChannel('dc1', conn, dispatcher);

      final errors = <String>[];
      Object? streamError;
      final sub = dc.onError.listen(errors.add, onError: (e) => streamError = e);
      addTearDown(sub.cancel);

      // 'error' field missing entirely — used to throw a cast error into the
      // stream, which is an unhandled zone error for onData-only listeners.
      dispatcher.broadcast(
          WsMessage(type: 'event:dc:error', id: 0, handle: 'dc1', data: {}));
      await Future<void>.delayed(Duration.zero);

      expect(streamError, isNull,
          reason: 'a malformed error event must not become a stream error');
      expect(errors, hasLength(1));
    });
  });

  group('DataChannelMessage', () {
    test('text does not throw on non-UTF8 binary payloads', () {
      final msg = DataChannelMessage(
        bytes: Uint8List.fromList([0xFF, 0xFE, 0x80]),
        isBinary: true,
      );
      expect(() => msg.text, returnsNormally,
          reason: 'reading .text on binary garbage must degrade gracefully, '
              'not throw FormatException');
    });
  });

  group('per-request timeout override', () {
    test('sendBinary honors a per-call timeout shorter than the default',
        () async {
      final server = _SilentWsServer();
      final url = await server.start();
      addTearDown(server.stop);

      final conn = WebSocketConnection(onMessage: (_) {});
      await conn.connect(url, token: 't');
      addTearDown(conn.close);

      final dispatcher = pion.EventDispatcher();
      final dc = PionDataChannel('dc1', conn, dispatcher);

      final sw = Stopwatch()..start();
      await expectLater(
        dc.sendBinary([1, 2, 3], timeout: const Duration(milliseconds: 200)),
        throwsA(isA<PionException>()
            .having((e) => e.code, 'code', 'OPERATION_TIMEOUT')),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the per-call timeout must override the 30s default');
    });
  });
}
