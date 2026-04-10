import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/event_dispatcher.dart' as pion;
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/reconnect.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';
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
    test('text message has isBinary false and text getter works', () {
      final msg = DataChannelMessage(
        bytes: Uint8List.fromList(utf8.encode('hello')),
        isBinary: false,
      );
      expect(msg.isBinary, isFalse);
      expect(msg.text, 'hello');
    });

    test('binary message exposes raw bytes', () {
      final msg = DataChannelMessage(
        bytes: Uint8List.fromList([1, 2, 3]),
        isBinary: true,
      );
      expect(msg.isBinary, isTrue);
      expect(msg.bytes, [1, 2, 3]);
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

  group('PionDataChannel', () {
    test('onBufferedAmountLow stream emits when event:bufferedAmountLow is broadcast',
        () async {
      final dispatcher = pion.EventDispatcher();
      // WebSocketConnection is not connected; we only need it for the
      // constructor — the stream test never calls request().
      final connection = WebSocketConnection(onMessage: (_) {});
      final dc = PionDataChannel(
        'test-handle-32charsxxxxxxxxxxxxxxxxx',
        connection,
        dispatcher,
        label: 'test',
      );

      var fired = false;
      dc.onBufferedAmountLow.listen((_) => fired = true);

      dispatcher.broadcast(WsMessage(
        type: 'event:bufferedAmountLow',
        id: 0,
        handle: 'test-handle-32charsxxxxxxxxxxxxxxxxx',
        data: {},
      ));

      await Future.delayed(Duration.zero);
      expect(fired, isTrue);
    });

    test('onBufferedAmountLow does not emit for unrelated event types', () async {
      final dispatcher = pion.EventDispatcher();
      final connection = WebSocketConnection(onMessage: (_) {});
      final dc = PionDataChannel(
        'test-handle-32charsxxxxxxxxxxxxxxxxx',
        connection,
        dispatcher,
        label: 'test',
      );

      var fired = false;
      dc.onBufferedAmountLow.listen((_) => fired = true);

      dispatcher.broadcast(WsMessage(
        type: 'event:dataChannelOpen',
        id: 0,
        handle: 'test-handle-32charsxxxxxxxxxxxxxxxxx',
        data: {},
      ));

      await Future.delayed(Duration.zero);
      expect(fired, isFalse);
    });

    test('onBufferedAmountLow does not emit for a different handle', () async {
      final dispatcher = pion.EventDispatcher();
      final connection = WebSocketConnection(onMessage: (_) {});
      final dc = PionDataChannel(
        'handle-a-32charsxxxxxxxxxxxxxxxxxxxxxxx',
        connection,
        dispatcher,
        label: 'test',
      );

      var fired = false;
      dc.onBufferedAmountLow.listen((_) => fired = true);

      dispatcher.broadcast(WsMessage(
        type: 'event:bufferedAmountLow',
        id: 0,
        handle: 'handle-b-32charsxxxxxxxxxxxxxxxxxxxxxxx',
        data: {},
      ));

      await Future.delayed(Duration.zero);
      expect(fired, isFalse);
    });
  });

  group('PionSettingsEngine', () {
    test('toMap returns empty map when all fields are null', () {
      const se = PionSettingsEngine();
      expect(se.toMap(), isEmpty);
    });

    test('toMap omits null fields', () {
      const se = PionSettingsEngine(receiveMtu: 1400);
      final map = se.toMap();
      expect(map.containsKey('receive_mtu'), isTrue);
      expect(map.length, 1);
    });

    test('toMap includes boolean flags', () {
      const se = PionSettingsEngine(
        disableActiveTcp: true,
        disableCertificateFingerprintVerification: false,
        disableCloseByDtls: true,
        disableSrtcpReplayProtection: false,
        disableSrtpReplayProtection: true,
        enableDataChannelBlockWrite: true,
        enableSctpZeroChecksum: true,
      );
      final map = se.toMap();
      expect(map['disable_active_tcp'], isTrue);
      expect(map['disable_certificate_fingerprint_verification'], isFalse);
      expect(map['disable_close_by_dtls'], isTrue);
      expect(map['disable_srtcp_replay_protection'], isFalse);
      expect(map['disable_srtp_replay_protection'], isTrue);
      expect(map['enable_data_channel_block_write'], isTrue);
      expect(map['enable_sctp_zero_checksum'], isTrue);
    });

    test('toMap includes numeric settings', () {
      const se = PionSettingsEngine(
        sctpMaxReceiveBufferSize: 4194304,
        sctpMaxMessageSize: 65536,
        receiveMtu: 1300,
        iceMaxBindingRequests: 7,
        dtlsReplayProtectionWindow: 64,
        srtcpReplayProtectionWindow: 64,
        srtpReplayProtectionWindow: 64,
        ephemeralUdpPortMin: 10000,
        ephemeralUdpPortMax: 20000,
      );
      final map = se.toMap();
      expect(map['sctp_max_receive_buffer_size'], 4194304);
      expect(map['sctp_max_message_size'], 65536);
      expect(map['receive_mtu'], 1300);
      expect(map['ice_max_binding_requests'], 7);
      expect(map['dtls_replay_protection_window'], 64);
      expect(map['srtcp_replay_protection_window'], 64);
      expect(map['srtp_replay_protection_window'], 64);
      expect(map['ephemeral_udp_port_min'], 10000);
      expect(map['ephemeral_udp_port_max'], 20000);
    });

    test('toMap includes duration settings', () {
      const se = PionSettingsEngine(
        iceDisconnectedTimeoutMs: 5000,
        iceFailedTimeoutMs: 25000,
        iceKeepaliveMs: 2000,
        hostAcceptanceMinWaitMs: 500,
        srflxAcceptanceMinWaitMs: 500,
        prflxAcceptanceMinWaitMs: 500,
        relayAcceptanceMinWaitMs: 500,
        dtlsRetransmissionIntervalMs: 100,
        stunGatherTimeoutMs: 3000,
      );
      final map = se.toMap();
      expect(map['ice_disconnected_timeout_ms'], 5000);
      expect(map['ice_failed_timeout_ms'], 25000);
      expect(map['ice_keepalive_ms'], 2000);
      expect(map['host_acceptance_min_wait_ms'], 500);
      expect(map['srflx_acceptance_min_wait_ms'], 500);
      expect(map['prflx_acceptance_min_wait_ms'], 500);
      expect(map['relay_acceptance_min_wait_ms'], 500);
      expect(map['dtls_retransmission_interval_ms'], 100);
      expect(map['stun_gather_timeout_ms'], 3000);
    });

    test('toMap includes string settings', () {
      const se = PionSettingsEngine(multicastDnsHostName: 'myhost.local');
      final map = se.toMap();
      expect(map['multicast_dns_host_name'], 'myhost.local');
    });

    test('toMap uses snake_case keys matching the Go wire protocol', () {
      const se = PionSettingsEngine(
        disableActiveTcp: true,
        ephemeralUdpPortMin: 1024,
        ephemeralUdpPortMax: 65535,
      );
      final map = se.toMap();
      // Verify exact key names that the Go side expects
      expect(map.containsKey('disable_active_tcp'), isTrue);
      expect(map.containsKey('ephemeral_udp_port_min'), isTrue);
      expect(map.containsKey('ephemeral_udp_port_max'), isTrue);
      // Verify no camelCase keys leaked through
      expect(map.containsKey('disableActiveTcp'), isFalse);
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
