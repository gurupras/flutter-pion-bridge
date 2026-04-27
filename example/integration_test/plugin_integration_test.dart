// Integration tests for the Linux platform-channel layer.
//
// These tests run inside a real Flutter Linux app, so every call to
// PionBridge.initialize() goes through the full native stack:
//
//   Dart MethodChannel → C++ plugin (pionbridge_plugin.cc)
//     → g_spawn_async_with_pipes (Go binary)
//       → pionserver WebSocket
//         → Dart WebSocketConnection
//
// Run with:
//   cd example
//   flutter test --device-id linux integration_test/plugin_integration_test.dart
//
// Requires a display (real or Xvfb).  The built Linux app bundle must already
// contain the pionbridge binary at <exe>/lib/pionbridge (produced by
// scripts/build_linux.sh).

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pion_bridge/pion_bridge.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Track every bridge created in a test so tearDown can close them all.
  final _bridges = <PionBridge>[];

  tearDown(() async {
    for (final b in List.of(_bridges)) {
      try {
        await b.close();
      } catch (_) {}
    }
    _bridges.clear();
  });

  /// Helper: initialize a bridge and register it for cleanup.
  Future<PionBridge> makeBridge({
    PionSettingsEngine? settingsEngine,
    void Function()? onDisconnected,
    void Function()? onReconnected,
    int? maxReconnectAttempts,
  }) async {
    final b = await PionBridge.initialize(
      settingsEngine: settingsEngine,
      onDisconnected: onDisconnected,
      onReconnected: onReconnected,
      maxReconnectAttempts: maxReconnectAttempts,
    );
    _bridges.add(b);
    return b;
  }

  group('Linux plugin — MethodChannel / native binary', () {
    // -------------------------------------------------------------------------
    // startServer basics
    // -------------------------------------------------------------------------

    test('startServer: bridge connects and isConnected is true', () async {
      final bridge = await makeBridge();
      expect(bridge.isConnected, isTrue);
    });

    test('startServer: createPeerConnection works through the full native stack',
        () async {
      final bridge = await makeBridge();
      final pc = await bridge.createPeerConnection();
      expect(pc, isNotNull);
      await pc.close();
    });

    test('startServer: createOffer returns non-empty SDP', () async {
      final bridge = await makeBridge();
      final pc = await bridge.createPeerConnection();
      final sdp = await pc.createOffer();
      expect(sdp, isNotEmpty);
      // The SDP must contain the WebRTC version line
      expect(sdp, contains('v=0'));
      await pc.close();
    });

    // -------------------------------------------------------------------------
    // startServer called a second time — old Go process must be killed
    //
    // The C++ plugin (handle_start_server) does:
    //   if (self->server_pid != 0) { kill(self->server_pid, SIGTERM); ... }
    // before spawning a new binary.  The old bridge's WebSocket should close
    // once the Go process exits.
    // -------------------------------------------------------------------------

    test(
        'startServer: second call kills old Go process — first bridge disconnects',
        () async {
      final disconnected = Completer<void>();
      final bridge1 = await makeBridge(
        onDisconnected: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
        // Don't retry — fire onDisconnected immediately when the connection drops.
        maxReconnectAttempts: 0,
      );
      expect(bridge1.isConnected, isTrue);

      // A second initialize() calls startServer again, which kills the old pid.
      await makeBridge();

      // The old bridge's WebSocket must close within a few seconds.
      await disconnected.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('bridge1 did not disconnect after old Go process was killed'),
      );
      expect(bridge1.isConnected, isFalse);
    });

    // -------------------------------------------------------------------------
    // PionSettingsEngine flows through to Go
    //
    // _init() calls _sendInit(), which sends the settings_engine map in the
    // "init" RPC.  If Go rejects the map the future would throw; reaching the
    // expect means the round-trip succeeded.
    // -------------------------------------------------------------------------

    test('PionSettingsEngine: init with settings flows through to Go without error',
        () async {
      final bridge = await makeBridge(
        settingsEngine: const PionSettingsEngine(
          sctpMaxReceiveBufferSize: 262144,
          enableDataChannelBlockWrite: true,
        ),
      );
      expect(bridge.isConnected, isTrue);
    });

    // -------------------------------------------------------------------------
    // Full WebRTC end-to-end through the native stack
    //
    // This is the deepest smoke-test of the MethodChannel path: it proves
    // that the binary the C++ plugin spawned is a fully functional Go WebRTC
    // server capable of completing ICE, DTLS, and SCTP negotiation.
    // -------------------------------------------------------------------------

    test(
        'full WebRTC flow: offer/answer/ICE/DataChannel message through native stack',
        () async {
      final bridge = await makeBridge();

      final pc1 = await bridge.createPeerConnection();
      final pc2 = await bridge.createPeerConnection();

      // Wire ICE trickle
      pc1.onIceCandidate.listen((c) => pc2.addIceCandidate(c));
      pc2.onIceCandidate.listen((c) => pc1.addIceCandidate(c));

      // DataChannel must be created before the offer
      final dc1 = await pc1.createDataChannel('e2e-test');

      // Set up pc2's DataChannel listener before the offer so we don't miss
      // the event:dataChannel event, which fires during SCTP negotiation
      // (before dc1.onOpen).
      final receivedText = Completer<String>();
      pc2.onDataChannel.listen((dc) {
        dc.onMessage.listen((msg) {
          if (!receivedText.isCompleted) receivedText.complete(msg.text);
        });
      });

      // Offer / answer
      final offer = await pc1.createOffer();
      await pc1.setLocalDescription(offer, 'offer');
      await pc2.setRemoteDescription(offer, 'offer');

      final answer = await pc2.createAnswer();
      await pc2.setLocalDescription(answer, 'answer');
      await pc1.setRemoteDescription(answer, 'answer');

      // Wait for both peers to reach "connected"
      await pc1.onConnectionStateChange
          .firstWhere((s) => s == ConnectionState.connected)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                fail('pc1 never reached ConnectionState.connected'),
          );

      // Wait for the DataChannel to open
      await dc1.onOpen.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('DataChannel never opened'),
      );

      await dc1.send('hello from native stack');

      expect(
        await receivedText.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('DataChannel message never arrived'),
        ),
        'hello from native stack',
      );

      await pc1.close();
      await pc2.close();
    });

    test(
        'full WebRTC flow: binary DataChannel message through native stack',
        () async {
      final bridge = await makeBridge();

      final pc1 = await bridge.createPeerConnection();
      final pc2 = await bridge.createPeerConnection();

      pc1.onIceCandidate.listen((c) => pc2.addIceCandidate(c));
      pc2.onIceCandidate.listen((c) => pc1.addIceCandidate(c));

      final dc1 = await pc1.createDataChannel('binary-test');

      final receivedBytes = Completer<Uint8List>();
      pc2.onDataChannel.listen((dc) {
        dc.onMessage.listen((msg) {
          if (msg.isBinary && !receivedBytes.isCompleted) {
            receivedBytes.complete(msg.bytes);
          }
        });
      });

      final offer = await pc1.createOffer();
      await pc1.setLocalDescription(offer, 'offer');
      await pc2.setRemoteDescription(offer, 'offer');

      final answer = await pc2.createAnswer();
      await pc2.setLocalDescription(answer, 'answer');
      await pc1.setRemoteDescription(answer, 'answer');

      await pc1.onConnectionStateChange
          .firstWhere((s) => s == ConnectionState.connected)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                fail('pc1 never reached ConnectionState.connected'),
          );

      await dc1.onOpen.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('DataChannel never opened'),
      );

      final payload = Uint8List.fromList([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD]);
      await dc1.sendBinary(payload);

      final received = await receivedBytes.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Binary DataChannel message never arrived'),
      );
      expect(received, payload);

      await pc1.close();
      await pc2.close();
    });

    test('large binary payload (4 MB) arrives intact', () async {
      // Pion's default SCTP receive buffer is ~1 MB, which is too small to
      // reassemble a 4 MB message.  Raise it on both sides.
      final bridge = await makeBridge(
        settingsEngine: const PionSettingsEngine(
          sctpMaxReceiveBufferSize: 8 * 1024 * 1024,
        ),
      );

      final pc1 = await bridge.createPeerConnection();
      final pc2 = await bridge.createPeerConnection();

      pc1.onIceCandidate.listen((c) => pc2.addIceCandidate(c));
      pc2.onIceCandidate.listen((c) => pc1.addIceCandidate(c));

      final dc1 = await pc1.createDataChannel('large-binary');

      // Generate 4 MB of deterministic pseudo-random bytes so the content is
      // non-trivial (not all zeros) and we can verify correctness.
      const payloadSize = 4 * 1024 * 1024;
      final rng = Random(42);
      final payload = Uint8List.fromList(
        List.generate(payloadSize, (_) => rng.nextInt(256)),
      );

      // Accumulate chunks in case SCTP delivers the large message in pieces.
      final chunks = <int>[];
      final allReceived = Completer<void>();
      pc2.onDataChannel.listen((dc) {
        dc.onMessage.listen((msg) {
          if (!msg.isBinary) return;
          chunks.addAll(msg.bytes);
          if (chunks.length >= payloadSize && !allReceived.isCompleted) {
            allReceived.complete();
          }
        });
      });

      final offer = await pc1.createOffer();
      await pc1.setLocalDescription(offer, 'offer');
      await pc2.setRemoteDescription(offer, 'offer');

      final answer = await pc2.createAnswer();
      await pc2.setLocalDescription(answer, 'answer');
      await pc1.setRemoteDescription(answer, 'answer');

      await pc1.onConnectionStateChange
          .firstWhere((s) => s == ConnectionState.connected)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                fail('pc1 never reached ConnectionState.connected'),
          );

      await dc1.onOpen.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('DataChannel never opened'),
      );

      await dc1.sendBinary(payload);

      await allReceived.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'Only received ${chunks.length} / $payloadSize bytes after 15 s',
        ),
      );

      expect(chunks.length, payloadSize);
      expect(Uint8List.fromList(chunks), payload);

      await pc1.close();
      await pc2.close();
    });

    // -------------------------------------------------------------------------
    // startServer + connectExisting — the worker-isolate-safe path
    //
    // Verifies that PionBridge.startServer (the new public split of the
    // bootstrap MethodChannel call) returns a usable PionServerEndpoint, and
    // that PionBridge.connectExisting can attach to that endpoint without ever
    // touching MethodChannel.  This is the path real apps will use to drive
    // pion from worker isolates.
    // -------------------------------------------------------------------------

    test(
        'startServer + connectExisting: endpoint round-trip through native stack',
        () async {
      final endpoint = await PionBridge.startServer();
      expect(endpoint.port, greaterThan(0));
      expect(endpoint.token, isNotEmpty);

      final bridge = await PionBridge.connectExisting(endpoint);
      _bridges.add(bridge);
      expect(bridge.isConnected, isTrue);

      // Endpoint must serialize and deserialize losslessly so it can ride a
      // SendPort across an isolate boundary.
      final restored = PionServerEndpoint.fromMap(endpoint.toMap());
      expect(restored.port, endpoint.port);
      expect(restored.token, endpoint.token);
    });

    test(
        'connectExisting: two bridges on the same server are independent',
        () async {
      // Models the real-world pattern: root isolate + worker isolate each
      // hold their own PionBridge against the same Go server.
      final endpoint = await PionBridge.startServer();

      final a = await PionBridge.connectExisting(endpoint);
      _bridges.add(a);
      final b = await PionBridge.connectExisting(endpoint);
      _bridges.add(b);

      final pcA = await a.createPeerConnection();
      final pcB = await b.createPeerConnection();
      expect(pcA.handle, isNot(pcB.handle));

      // Closing one bridge does not invalidate the other's connection.
      await a.close();
      _bridges.remove(a);
      expect(b.isConnected, isTrue);

      final pcC = await b.createPeerConnection();
      expect(pcC.handle, isNotEmpty);
    });

    test(
        'connectExisting: full WebRTC flow over a connectExisting bridge',
        () async {
      final endpoint = await PionBridge.startServer();
      final bridge = await PionBridge.connectExisting(endpoint);
      _bridges.add(bridge);

      final pc1 = await bridge.createPeerConnection();
      final pc2 = await bridge.createPeerConnection();

      pc1.onIceCandidate.listen((c) => pc2.addIceCandidate(c));
      pc2.onIceCandidate.listen((c) => pc1.addIceCandidate(c));

      final dc1 = await pc1.createDataChannel('connect-existing-e2e');

      final receivedText = Completer<String>();
      pc2.onDataChannel.listen((dc) {
        dc.onMessage.listen((msg) {
          if (!receivedText.isCompleted) receivedText.complete(msg.text);
        });
      });

      final offer = await pc1.createOffer();
      await pc1.setLocalDescription(offer, 'offer');
      await pc2.setRemoteDescription(offer, 'offer');

      final answer = await pc2.createAnswer();
      await pc2.setLocalDescription(answer, 'answer');
      await pc1.setRemoteDescription(answer, 'answer');

      await pc1.onConnectionStateChange
          .firstWhere((s) => s == ConnectionState.connected)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                fail('pc1 never reached ConnectionState.connected'),
          );

      await dc1.onOpen.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('DataChannel never opened'),
      );

      // dc.send is fire-and-forget (returns void); no await needed.
      dc1.send('hello over connectExisting');

      expect(
        await receivedText.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('DataChannel message never arrived'),
        ),
        'hello over connectExisting',
      );

      await pc1.close();
      await pc2.close();
    });
  });
}
