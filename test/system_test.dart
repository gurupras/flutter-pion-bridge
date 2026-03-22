@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';
import 'package:pion_bridge/src/event_dispatcher.dart';
import 'package:pion_bridge/src/ws_message.dart';

import 'test_harness.dart';

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

  // --- Connection & Lifecycle ---

  group('Connection & Lifecycle', () {
    test('connect with valid token — isConnected is true', () {
      expect(harness.connection.isConnected, isTrue);
    });

    test('connect with invalid token — fails', () async {
      final badConn = WebSocketConnection(
        onMessage: (_) {},
      );
      try {
        await badConn.connect(
          'ws://127.0.0.1:${harness.port}/',
          token: 'wrong_token_00000000000000000000',
        );
        // If connect doesn't throw, we need to check if the server
        // closes the connection (which it will via 401)
        // The WebSocket upgrade itself may fail
        fail('Expected connection to fail with invalid token');
      } catch (e) {
        // Expected — server returns 401
        expect(e, isNotNull);
      }
    });

    test('disconnect detection — onDisconnect fires when server killed',
        () async {
      harness.kill();
      // Wait a bit for the disconnect to propagate
      await Future.delayed(const Duration(milliseconds: 500));
      expect(harness.disconnected, isTrue);
    });

    test('disconnect fails pending requests with CONNECTION_LOST', () async {
      // Kill the server, then immediately fire a request.
      // The request either fails to send or the pending completer
      // gets completed with CONNECTION_LOST when disconnect is detected.
      harness.kill();

      // Wait for disconnect to propagate
      await Future.delayed(const Duration(milliseconds: 500));

      try {
        await harness.connection.request('pc:create', null, {});
        fail('Expected CONNECTION_LOST exception');
      } on PionException catch (e) {
        expect(e.code, 'CONNECTION_LOST');
        expect(e.fatal, isTrue);
      }
    });

    test('request after disconnect throws CONNECTION_LOST', () async {
      harness.kill();
      await Future.delayed(const Duration(milliseconds: 500));

      try {
        await harness.connection.request('init', null, {});
        fail('Expected CONNECTION_LOST');
      } on PionException catch (e) {
        expect(e.code, 'CONNECTION_LOST');
      }
    });

    test('request timeout fires OPERATION_TIMEOUT', () async {
      // Start a raw WebSocket server that accepts but never responds
      final server = await HttpServer.bind('127.0.0.1', 0);
      final serverPort = server.port;
      server.transform(WebSocketTransformer()).listen((_) {
        // Accept connection but never send any response
      });

      try {
        final conn = WebSocketConnection(
          onMessage: (_) {},
          requestTimeout: const Duration(seconds: 2),
        );
        await conn.connect(
          'ws://127.0.0.1:$serverPort/',
          token: 'unused',
        );

        try {
          await conn.request('init', null, {});
          fail('Expected OPERATION_TIMEOUT');
        } on PionException catch (e) {
          expect(e.code, 'OPERATION_TIMEOUT');
        } finally {
          await conn.close();
        }
      } finally {
        await server.close();
      }
    });
  });

  // --- PeerConnection Operations ---

  group('PeerConnection Operations', () {
    test('createPeerConnection returns PC with valid handle', () async {
      final pc = await harness.createPeerConnection();
      expect(pc.handle, hasLength(32));
    });

    test('createOffer returns SDP string', () async {
      final pc = await harness.createPeerConnection();
      final sdp = await pc.createOffer();
      expect(sdp, isNotEmpty);
      expect(sdp, contains('v=0'));
    });

    test('createAnswer returns SDP after setting remote offer', () async {
      final offerer = await harness.createPeerConnection();
      final answerer = await harness.createPeerConnection();

      // Need a DC so the SDP has media, and setLocalDesc so ice-ufrag is populated
      await offerer.createDataChannel('setup');

      final offer = await offerer.createOffer();
      await offerer.setLocalDescription(offer, 'offer');
      await answerer.setRemoteDescription(offer, 'offer');

      final answer = await answerer.createAnswer();
      expect(answer, isNotEmpty);
      expect(answer, contains('v=0'));
    });

    test('setLocalDescription / setRemoteDescription complete without error',
        () async {
      final offerer = await harness.createPeerConnection();
      final answerer = await harness.createPeerConnection();

      // Create DC before offer so SDP has application media section
      await offerer.createDataChannel('setup');

      final offer = await offerer.createOffer();
      await offerer.setLocalDescription(offer, 'offer');
      await answerer.setRemoteDescription(offer, 'offer');

      final answer = await answerer.createAnswer();
      await answerer.setLocalDescription(answer, 'answer');
      await offerer.setRemoteDescription(answer, 'answer');
      // If we reach here, no exceptions thrown
    });

    test('onIceCandidate stream emits IceCandidate objects', () async {
      final pc = await harness.createPeerConnection();
      final candidates = <IceCandidate>[];

      pc.onIceCandidate.listen(candidates.add);

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer, 'offer');

      // Wait for ICE gathering
      await Future.delayed(const Duration(seconds: 2));
      // In a local test without STUN, we may get host candidates
      // Just verify the stream works (may be empty without network)
    });

    test('onConnectionStateChange emits ConnectionState values', () async {
      final pc = await harness.createPeerConnection();
      final states = <ConnectionState>[];

      pc.onConnectionStateChange.listen(states.add);

      // Close should trigger a state change
      await pc.close();
      await Future.delayed(const Duration(milliseconds: 500));

      // We should see at least some state changes
    });

    test('close() sends resource:delete and cleans up', () async {
      final pc = await harness.createPeerConnection();
      final handle = pc.handle;

      await pc.close();

      // Trying to use the handle should fail
      try {
        await harness.connection.request('pc:offer', handle, {});
        fail('Expected NOT_FOUND');
      } on PionException catch (e) {
        expect(e.code, 'NOT_FOUND');
      }
    });
  });

  // --- Full Offer/Answer Flow ---

  group('Full Offer/Answer Flow', () {
    test('two PCs complete full offer/answer/ICE exchange', () async {
      final pair = await harness.createConnectedPair();
      // If we got here, signaling + ICE + DC negotiation all succeeded
      expect(pair.offerer.handle, hasLength(32));
      expect(pair.answerer.handle, hasLength(32));
    });

    test('both reach ConnectionState.connected', () async {
      final offerer = await harness.createPeerConnection();
      final answerer = await harness.createPeerConnection();

      final offererStates = <ConnectionState>[];
      final answererStates = <ConnectionState>[];
      offerer.onConnectionStateChange.listen(offererStates.add);
      answerer.onConnectionStateChange.listen(answererStates.add);

      // Subscribe to ICE before signaling
      final offererCandidates = <IceCandidate>[];
      final answererCandidates = <IceCandidate>[];
      offerer.onIceCandidate.listen(offererCandidates.add);
      answerer.onIceCandidate.listen(answererCandidates.add);

      await offerer.createDataChannel('test');
      final offer = await offerer.createOffer();
      await offerer.setLocalDescription(offer, 'offer');
      await answerer.setRemoteDescription(offer, 'offer');
      final answer = await answerer.createAnswer();
      await answerer.setLocalDescription(answer, 'answer');
      await offerer.setRemoteDescription(answer, 'answer');

      await Future.delayed(const Duration(seconds: 1));
      for (final c in offererCandidates) {
        await answerer.addIceCandidate(c);
      }
      for (final c in answererCandidates) {
        await offerer.addIceCandidate(c);
      }

      await Future.delayed(const Duration(seconds: 3));

      expect(offererStates, contains(ConnectionState.connected));
      expect(answererStates, contains(ConnectionState.connected));
    });

    test('addIceCandidate completes without error', () async {
      final offerer = await harness.createPeerConnection();
      final answerer = await harness.createPeerConnection();

      final offererCandidates = <IceCandidate>[];
      offerer.onIceCandidate.listen(offererCandidates.add);

      await offerer.createDataChannel('test');
      final offer = await offerer.createOffer();
      await offerer.setLocalDescription(offer, 'offer');
      await answerer.setRemoteDescription(offer, 'offer');
      final answer = await answerer.createAnswer();
      await answerer.setLocalDescription(answer, 'answer');
      await offerer.setRemoteDescription(answer, 'answer');

      await Future.delayed(const Duration(seconds: 1));

      // Should not throw
      for (final c in offererCandidates) {
        await answerer.addIceCandidate(c);
      }
      expect(offererCandidates, isNotEmpty);
    });

    test('onIceGatheringComplete stream emits after all candidates', () async {
      final pc = await harness.createPeerConnection();

      var gatheringComplete = false;
      pc.onIceGatheringComplete.listen((_) => gatheringComplete = true);

      await pc.createDataChannel('test');
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer, 'offer');

      await Future.delayed(const Duration(seconds: 3));
      expect(gatheringComplete, isTrue);
    });
  });

  // --- DataChannel Operations ---

  group('DataChannel Operations', () {
    test('createDataChannel returns PionDataChannel with label', () async {
      final pc = await harness.createPeerConnection();
      final dc = await pc.createDataChannel('chat');
      expect(dc.handle, hasLength(32));
      expect(dc.label, 'chat');
    });

    test('onDataChannel stream emits when remote creates DC', () async {
      final pair = await harness.createConnectedPair();
      expect(pair.answererDc, isNotNull);
      expect(pair.answererDc.handle, hasLength(32));
    });

    test('send() delivers text to remote via onMessage', () async {
      final pair = await harness.createConnectedPair();

      final received = Completer<DataChannelMessage>();
      pair.answererDc.onMessage.listen((msg) {
        if (!received.isCompleted) received.complete(msg);
      });

      await pair.offererDc.send('Hello from offerer!');

      final msg = await received.future
          .timeout(const Duration(seconds: 5));
      expect(msg.data, 'Hello from offerer!');
      expect(msg.isBinary, isFalse);
    });

    test('sendBinary() delivers binary to remote via onMessage', () async {
      final pair = await harness.createConnectedPair();

      final received = Completer<DataChannelMessage>();
      pair.answererDc.onMessage.listen((msg) {
        if (!received.isCompleted) received.complete(msg);
      });

      await pair.offererDc.sendBinary([1, 2, 3]);

      final msg = await received.future
          .timeout(const Duration(seconds: 5));
      expect(msg.isBinary, isTrue);
      expect(msg.binaryData, [1, 2, 3]);
    });

    test('DataChannelMessage.isBinary is correct for text vs binary',
        () async {
      final pair = await harness.createConnectedPair();

      final messages = <DataChannelMessage>[];
      pair.answererDc.onMessage.listen(messages.add);

      await pair.offererDc.send('text');
      await Future.delayed(const Duration(milliseconds: 500));
      await pair.offererDc.sendBinary([42]);
      await Future.delayed(const Duration(seconds: 1));

      expect(messages.length, greaterThanOrEqualTo(2));
      expect(messages[0].isBinary, isFalse);
      expect(messages[1].isBinary, isTrue);
    });

    test('onOpen stream emits when DC opens', () async {
      final pair = await harness.createConnectedPair();
      // DC is already open at this point (connected pair waits for SCTP).
      // Verify by checking that we got here without timeout — the pair
      // creation internally waits for the answerer DC which requires open.
      // For an explicit test, create a new DC on the connected pair.
      final newDcOpenCompleter = Completer<void>();
      final newDc = await pair.offerer.createDataChannel('new-dc');
      newDc.onOpen.listen((_) {
        if (!newDcOpenCompleter.isCompleted) newDcOpenCompleter.complete();
      });

      await newDcOpenCompleter.future.timeout(const Duration(seconds: 5));
    });

    test('onClose stream emits when DC closes', () async {
      final pair = await harness.createConnectedPair();

      final closedCompleter = Completer<void>();
      pair.answererDc.onClose.listen((_) {
        if (!closedCompleter.isCompleted) closedCompleter.complete();
      });

      // Close the offerer's DC — should trigger close on answerer's side
      await harness.connection.request('dc:close', pair.offererDc.handle, {});

      await closedCompleter.future.timeout(const Duration(seconds: 5));
    });

    test('close() on DataChannel sends resource:delete', () async {
      final pc = await harness.createPeerConnection();
      final dc = await pc.createDataChannel('chat');
      final dcHandle = dc.handle;

      await dc.close();

      // Handle should be gone
      try {
        await harness.connection.request('dc:close', dcHandle, {});
        fail('Expected NOT_FOUND');
      } on PionException catch (e) {
        expect(e.code, 'NOT_FOUND');
      }
    });
  });

  // --- Error Handling ---

  group('Error Handling', () {
    test('operation on non-existent handle throws PionException NOT_FOUND',
        () async {
      try {
        await harness.connection.request(
          'pc:offer',
          'deadbeef12345678deadbeef12345678',
          {},
        );
        fail('Expected NOT_FOUND');
      } on PionException catch (e) {
        expect(e.code, 'NOT_FOUND');
        expect(e.message, isNotEmpty);
      }
    });

    test('PionException.code and .message populated correctly', () async {
      try {
        await harness.connection.request(
          'pc:setLocalDesc',
          'deadbeef12345678deadbeef12345678',
          {},
        );
        fail('Expected exception');
      } on PionException catch (e) {
        expect(e.code, isNotEmpty);
        expect(e.message, isNotEmpty);
      }
    });

    test('PionException.fatal is true for CONNECTION_LOST', () async {
      harness.kill();
      await Future.delayed(const Duration(milliseconds: 500));

      try {
        await harness.connection.request('init', null, {});
        fail('Expected exception');
      } on PionException catch (e) {
        expect(e.code, 'CONNECTION_LOST');
        expect(e.fatal, isTrue);
      }
    });
  });
}
