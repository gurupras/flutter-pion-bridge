import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/event_dispatcher.dart' as pion;
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/reconnect.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/ws_message.dart';

void main() {
  group('WsMessage', () {
    test('toMap/fromMap round-trips correctly', () {
      final msg = WsMessage(
        type: 'pc:create',
        id: 42,
        handle: 'abc123',
        data: {'key': 'value', 'num': 5},
      );

      final map = msg.toMap();
      final restored = WsMessage.fromMap(map);

      expect(restored.type, 'pc:create');
      expect(restored.id, 42);
      expect(restored.handle, 'abc123');
      expect(restored.data['key'], 'value');
      expect(restored.data['num'], 5);
    });

    test('toMap omits null handle', () {
      final msg = WsMessage(type: 'init', id: 1, data: {});
      final map = msg.toMap();
      expect(map.containsKey('handle'), isFalse);
    });

    test('fromMap handles missing data', () {
      final msg = WsMessage.fromMap({'type': 'init', 'id': 1});
      expect(msg.data, isEmpty);
    });
  });

  group('EventDispatcher', () {
    test('routes events to correct handle', () async {
      final dispatcher = pion.EventDispatcher();
      final events = <WsMessage>[];

      dispatcher.listen('handle-a').listen(events.add);

      dispatcher.broadcast(WsMessage(
        type: 'event:test',
        id: 0,
        handle: 'handle-a',
        data: {'msg': 'hello'},
      ));

      // Give the stream a chance to deliver
      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first.data['msg'], 'hello');
    });

    test('ignores events for unregistered handles', () async {
      final dispatcher = pion.EventDispatcher();
      final events = <WsMessage>[];

      dispatcher.listen('handle-a').listen(events.add);

      dispatcher.broadcast(WsMessage(
        type: 'event:test',
        id: 0,
        handle: 'handle-b',
        data: {},
      ));

      await Future.delayed(Duration.zero);

      expect(events, isEmpty);
    });

    test('unsubscribe closes stream', () async {
      final dispatcher = pion.EventDispatcher();
      var done = false;

      dispatcher.listen('handle-a').listen(
        (_) {},
        onDone: () => done = true,
      );

      dispatcher.unsubscribe('handle-a');

      await Future.delayed(Duration.zero);
      expect(done, isTrue);
    });
  });

  group('PionException', () {
    test('fromWsMessage populates fields correctly', () {
      final msg = WsMessage(
        type: 'error',
        id: 5,
        data: {
          'code': 'NOT_FOUND',
          'message': 'handle not found',
          'fatal': false,
          'handle': 'abc123',
        },
      );

      final ex = PionException.fromWsMessage(msg);
      expect(ex.code, 'NOT_FOUND');
      expect(ex.message, 'handle not found');
      expect(ex.fatal, isFalse);
      expect(ex.handle, 'abc123');
    });

    test('fatal is true for CONNECTION_LOST', () {
      final ex = PionException('CONNECTION_LOST', 'disconnected', fatal: true);
      expect(ex.fatal, isTrue);
    });

    test('toString includes code and message', () {
      final ex = PionException('INTERNAL_ERROR', 'something broke');
      expect(ex.toString(), 'PionException(INTERNAL_ERROR): something broke');
    });
  });

  group('ConnectionState', () {
    test('fromString("new") returns newConnection', () {
      expect(
        ConnectionState.fromString('new'),
        ConnectionState.newConnection,
      );
    });

    test('fromString("connected") returns connected', () {
      expect(
        ConnectionState.fromString('connected'),
        ConnectionState.connected,
      );
    });

    test('fromString("failed") returns failed', () {
      expect(ConnectionState.fromString('failed'), ConnectionState.failed);
    });
  });

  group('DataChannelMessage', () {
    test('text message has isBinary false', () {
      final msg = DataChannelMessage(data: 'hello', isBinary: false);
      expect(msg.isBinary, isFalse);
      expect(msg.data, 'hello');
    });

    test('binary message decodes base64', () {
      // "AQID" is base64 for [1, 2, 3]
      final msg = DataChannelMessage(data: 'AQID', isBinary: true);
      expect(msg.isBinary, isTrue);
      expect(msg.binaryData, [1, 2, 3]);
    });
  });

  group('ReconnectingWebSocketConnection backoff', () {
    test('attempt 0 returns baseDelay', () {
      final conn = ReconnectingWebSocketConnection(onMessage: (_) {});
      expect(conn.backoffDelay(0), const Duration(seconds: 1));
    });

    test('attempt 1 returns 2×base', () {
      final conn = ReconnectingWebSocketConnection(onMessage: (_) {});
      expect(conn.backoffDelay(1), const Duration(seconds: 2));
    });

    test('attempt 4 returns 16s', () {
      final conn = ReconnectingWebSocketConnection(onMessage: (_) {});
      expect(conn.backoffDelay(4), const Duration(seconds: 16));
    });

    test('delay is capped at maxDelay', () {
      final conn = ReconnectingWebSocketConnection(onMessage: (_) {});
      expect(conn.backoffDelay(10), const Duration(seconds: 30));
    });

    test('custom baseDelay and maxDelay respected', () {
      final conn = ReconnectingWebSocketConnection(
        onMessage: (_) {},
        baseDelay: const Duration(milliseconds: 500),
        maxDelay: const Duration(seconds: 5),
      );
      expect(conn.backoffDelay(0), const Duration(milliseconds: 500));
      expect(conn.backoffDelay(4), const Duration(seconds: 5)); // capped
    });
  });

  group('IceServer', () {
    test('toMap includes urls', () {
      final server = IceServer(urls: ['stun:stun.l.google.com:19302']);
      final map = server.toMap();
      expect(map['urls'], ['stun:stun.l.google.com:19302']);
      expect(map.containsKey('username'), isFalse);
    });

    test('toMap includes credentials when set', () {
      final server = IceServer(
        urls: ['turn:turn.example.com'],
        username: 'user',
        credential: 'pass',
      );
      final map = server.toMap();
      expect(map['username'], 'user');
      expect(map['credential'], 'pass');
    });
  });
}
