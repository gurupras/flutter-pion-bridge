// Integration tests for PionBridge.connectExisting — the worker-isolate-safe
// constructor that attaches to an already-running Go server without touching
// MethodChannel.
//
// The Go server is started by TestHarness as a subprocess, which prints a
// JSON line {"port":N,"token":"…"} to stdout.  These tests build a
// PionServerEndpoint from those values (mirroring what root-isolate code
// would obtain from PionBridge.startServer) and then call
// PionBridge.connectExisting from this VM context.
//
// MethodChannel is never invoked here, so these tests would also pass when
// run from a worker isolate.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/bridge.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';

import '../helpers/test_harness.dart';

void main() {
  late TestHarness harness;

  setUpAll(() async {
    await TestHarness.ensureBinary();
  });

  tearDownAll(() {
    TestHarness.cleanupBinary();
  });

  setUp(() async {
    harness = TestHarness();
    await harness.start();
  });

  tearDown(() async {
    await harness.stop();
  });

  PionServerEndpoint endpoint() =>
      PionServerEndpoint(port: harness.port, token: harness.token);

  group('PionBridge.connectExisting', () {
    test('connects to a running server and reports isConnected', () async {
      final pion = await PionBridge.connectExisting(endpoint());
      expect(pion.isConnected, isTrue);
      await pion.close();
    });

    test('rejects an invalid token', () async {
      final bad = PionServerEndpoint(port: harness.port, token: 'wrong-token');
      expect(
        () => PionBridge.connectExisting(bad),
        throwsA(anything),
      );
    });

    test('can drive a full WebRTC handshake without MethodChannel', () async {
      final pion = await PionBridge.connectExisting(endpoint());
      try {
        final offerer = await pion.createPeerConnection();
        final answerer = await pion.createPeerConnection();

        final offererCandidates = <IceCandidate>[];
        final answererCandidates = <IceCandidate>[];
        offerer.onIceCandidate.listen(offererCandidates.add);
        answerer.onIceCandidate.listen(answererCandidates.add);

        final offererConnected = Completer<void>();
        offerer.onConnectionStateChange.listen((state) {
          if (state == ConnectionState.connected &&
              !offererConnected.isCompleted) {
            offererConnected.complete();
          }
        });

        await offerer.createDataChannel('test');

        final offer = await offerer.createOffer();
        await offerer.setLocalDescription(offer, 'offer');
        await answerer.setRemoteDescription(offer, 'offer');

        final answer = await answerer.createAnswer();
        await answerer.setLocalDescription(answer, 'answer');
        await offerer.setRemoteDescription(answer, 'answer');

        await Future<void>.delayed(const Duration(seconds: 1));

        for (final c in List.of(offererCandidates)) {
          await answerer.addIceCandidate(c);
        }
        for (final c in List.of(answererCandidates)) {
          await offerer.addIceCandidate(c);
        }

        await offererConnected.future
            .timeout(const Duration(seconds: 10));
      } finally {
        await pion.close();
      }
    });

    test('two PionBridge instances on the same server are independent',
        () async {
      // Simulates the root-isolate + worker-isolate pattern: both connect to
      // the same Go server and each owns its own resources.
      final a = await PionBridge.connectExisting(endpoint());
      final b = await PionBridge.connectExisting(endpoint());
      try {
        final pcA = await a.createPeerConnection();
        final pcB = await b.createPeerConnection();

        // Distinct handles — each bridge created its own resource.
        expect(pcA.handle, isNot(pcB.handle));

        // Closing bridge A does not invalidate bridge B's connection.
        await a.close();
        expect(b.isConnected, isTrue);

        // Bridge B can still issue requests and create new resources.
        final pcC = await b.createPeerConnection();
        expect(pcC.handle, isNotEmpty);
      } finally {
        await b.close();
      }
    });

    test(
        'dc:send works after the connection that created the DC has closed '
        '(regression: per-Handler send queue must not leak)',
        () async {
      // Regression test: prior to moving sendChs onto the Registry, a DC's
      // send queue was owned by the Handler that created it.  When that
      // connection closed, any later dc:send from a different connection
      // would fail with "dc:send on unknown handle: …".  This is the exact
      // scenario the worker-isolate pattern hits: the answerer worker
      // creates the DC, then exits while the message-sender worker takes
      // over.
      final creator = await PionBridge.connectExisting(endpoint());
      final partner = await PionBridge.connectExisting(endpoint());

      final offerer = await creator.createPeerConnection();
      final answerer = await partner.createPeerConnection();

      final offererCandidates = <IceCandidate>[];
      final answererCandidates = <IceCandidate>[];
      offerer.onIceCandidate.listen(offererCandidates.add);
      answerer.onIceCandidate.listen(answererCandidates.add);

      final offererDc = await offerer.createDataChannel('regression');
      final received = Completer<String>();
      offererDc.onMessage.listen((m) {
        if (!received.isCompleted) received.complete(m.text);
      });

      final dcOpen = Completer<void>();
      offererDc.onOpen.listen((_) {
        if (!dcOpen.isCompleted) dcOpen.complete();
      });

      final answererDcCompleter = Completer<PionDataChannel>();
      answerer.onDataChannel.listen((dc) {
        if (!answererDcCompleter.isCompleted) answererDcCompleter.complete(dc);
      });

      final offer = await offerer.createOffer();
      await offerer.setLocalDescription(offer, 'offer');
      await answerer.setRemoteDescription(offer, 'offer');

      final answer = await answerer.createAnswer();
      await answerer.setLocalDescription(answer, 'answer');
      await offerer.setRemoteDescription(answer, 'answer');

      await Future<void>.delayed(const Duration(seconds: 1));

      for (final c in List.of(offererCandidates)) {
        await answerer.addIceCandidate(c);
      }
      for (final c in List.of(answererCandidates)) {
        await offerer.addIceCandidate(c);
      }

      await dcOpen.future.timeout(const Duration(seconds: 10));
      final answererDc =
          await answererDcCompleter.future.timeout(const Duration(seconds: 10));
      final answererDcHandle = answererDc.handle;

      // Close the connection that created the answerer's DC.  Before the fix
      // this orphaned the DC's send queue (which was per-Handler), so any
      // later dc:send from a different connection failed silently with
      // "dc:send on unknown handle".
      await partner.close();

      // Issue dc:send from a brand-new raw WebSocket connection — neither
      // the creator nor the partner bridge.  This is the path that exposed
      // the bug: the sender's handler has no per-handler state for the DC,
      // so the lookup must hit the registry-backed queue.
      final senderConn = WebSocketConnection(onMessage: (_) {});
      try {
        await senderConn.connect(
          'ws://127.0.0.1:${harness.port}/',
          token: harness.token,
        );
        senderConn.send('dc:send', answererDcHandle, <String, dynamic>{
          'data': 'hello after close',
          'is_binary': false,
        });

        final got =
            await received.future.timeout(const Duration(seconds: 5));
        expect(got, 'hello after close');
      } finally {
        await senderConn.close();
        await creator.close();
      }
    });

    test('PionSettingsEngine is honored by connectExisting', () async {
      // Sending a SettingsEngine config exercises the same `init` round-trip
      // that PionBridge.initialize uses; confirms the code path is shared.
      final pion = await PionBridge.connectExisting(
        endpoint(),
        settingsEngine: const PionSettingsEngine(
          ephemeralUdpPortMin: 50000,
          ephemeralUdpPortMax: 50100,
        ),
      );
      try {
        // If init failed, isConnected would have flipped to false, or
        // createPeerConnection would throw.
        final pc = await pion.createPeerConnection();
        expect(pc.handle, hasLength(32));
      } finally {
        await pion.close();
      }
    });

    test('endpoint survives a SendPort round-trip and connectExisting works '
        'from a spawned isolate', () async {
      // End-to-end test of the documented worker pattern:
      //   root → startServer() → ship endpoint via SendPort
      //   worker → PionBridge.connectExisting(endpoint) → drive pion
      //
      // Here we simulate startServer() with the already-running test harness;
      // the rest is exactly what real users would write.
      final recv = ReceivePort();
      await Isolate.spawn(_workerEntry, recv.sendPort);
      final iter = StreamIterator(recv);

      await iter.moveNext();
      final workerSend = iter.current as SendPort;
      workerSend.send(endpoint().toMap());

      await iter.moveNext();
      final result = iter.current as Map;
      recv.close();

      expect(result['ok'], isTrue);
      expect(result['handle'] as String, hasLength(32));
      expect(result['sdp'] as String, contains('v=0'));
    });
  });
}

/// Worker-isolate entry point — must be a top-level function.
///
/// Receives a serialized PionServerEndpoint, reconstructs it, calls
/// PionBridge.connectExisting (the path under test), and exercises a real
/// RPC round-trip.
Future<void> _workerEntry(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);
  final msgs = StreamIterator(myPort);

  await msgs.moveNext();
  final endpointMap = msgs.current as Map;
  final endpoint = PionServerEndpoint.fromMap(endpointMap);

  try {
    final pion = await PionBridge.connectExisting(endpoint);
    final pc = await pion.createPeerConnection();
    await pc.createDataChannel('worker-channel');
    final sdp = await pc.createOffer();
    final handle = pc.handle;
    await pion.close();
    myPort.close();
    coordinator.send({'ok': true, 'handle': handle, 'sdp': sdp});
  } catch (e, st) {
    myPort.close();
    coordinator.send({'ok': false, 'error': e.toString(), 'stack': '$st'});
  }
}
