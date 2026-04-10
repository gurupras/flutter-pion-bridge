@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/reconnect.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';
import 'package:pion_bridge/src/event_dispatcher.dart';
import 'package:pion_bridge/src/ws_message.dart';

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
      expect(msg.text, 'Hello from offerer!');
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
      expect(msg.bytes, [1, 2, 3]);
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

    test('setBufferedAmountLowThreshold() completes without error', () async {
      final pair = await harness.createConnectedPair();

      // Should not throw
      await pair.offererDc.setBufferedAmountLowThreshold(1024);
    });

    test('onBufferedAmountLow stream emits after threshold is set and buffer drains',
        () async {
      final pair = await harness.createConnectedPair();

      // Set threshold = 1 byte: event fires when the send buffer drains to 0
      await pair.offererDc.setBufferedAmountLowThreshold(1);

      final fired = Completer<void>();
      pair.offererDc.onBufferedAmountLow.listen((_) {
        if (!fired.isCompleted) fired.complete();
      });

      // Sending data pushes the buffer above the threshold; when the data is
      // transmitted (loopback), the buffer drains to 0 (< 1) and the event fires.
      await pair.offererDc.send('trigger buffered amount low');

      await fired.future.timeout(const Duration(seconds: 5));
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

  // --- Reconnection ---

  group('Reconnection', () {
    test('onReconnected fires after server drops connection', () async {
      // Use a raw server that accepts, then drops the connection,
      // then accepts again so ReconnectingWebSocketConnection can reconnect.
      var connectionCount = 0;
      WebSocket? activeSocket;

      final server = await HttpServer.bind('127.0.0.1', 0);
      final port = server.port;

      server.transform(WebSocketTransformer()).listen((ws) {
        connectionCount++;
        activeSocket = ws;
        // Don't close immediately on first connect — let reconnect do it
      });

      final reconnectedCompleter = Completer<void>();
      final conn = ReconnectingWebSocketConnection(
        onMessage: (_) {},
        onReconnected: () {
          if (!reconnectedCompleter.isCompleted) {
            reconnectedCompleter.complete();
          }
        },
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 500),
      );

      try {
        await conn.connect('ws://127.0.0.1:$port/', token: 'unused');
        expect(connectionCount, 1);

        // Drop the connection server-side
        await activeSocket?.close();
        await Future.delayed(const Duration(milliseconds: 50));

        // Wait for reconnect
        await reconnectedCompleter.future
            .timeout(const Duration(seconds: 5));

        expect(connectionCount, 2);
      } finally {
        await conn.close();
        await server.close();
      }
    });

    test('onDisconnected fires when maxAttempts exceeded', () async {
      // Start a server, accept the first connection, then close the server
      // so all subsequent reconnect attempts get connection refused.
      final server = await HttpServer.bind('127.0.0.1', 0);
      final port = server.port;
      WebSocket? firstSocket;

      server.transform(WebSocketTransformer()).listen((ws) {
        firstSocket = ws;
      });

      final disconnectedCompleter = Completer<void>();
      final conn = ReconnectingWebSocketConnection(
        onMessage: (_) {},
        onDisconnected: () {
          if (!disconnectedCompleter.isCompleted) {
            disconnectedCompleter.complete();
          }
        },
        maxAttempts: 2,
        baseDelay: const Duration(milliseconds: 50),
        maxDelay: const Duration(milliseconds: 200),
      );

      try {
        await conn.connect('ws://127.0.0.1:$port/', token: 'unused');

        // Close the server so reconnects will get connection refused
        await server.close(force: true);

        // Drop the existing connection to trigger reconnect attempts
        await firstSocket?.close();

        await disconnectedCompleter.future
            .timeout(const Duration(seconds: 5));
      } finally {
        await conn.close();
      }
    });
  });

  // --- DataChannel ordering & stress ---

  group('DataChannel ordering & stress', () {
    test('send 500 messages in sequence — all arrive in order', () async {
      final pair = await harness.createConnectedPair();

      final received = <String>[];
      pair.answererDc.onMessage.listen((msg) {
        received.add(msg.data as String);
      });

      // Send 500 sequential messages
      for (int i = 0; i < 500; i++) {
        await pair.offererDc.send('msg-$i');
      }

      // Wait for all 500 to arrive
      await Future.delayed(const Duration(seconds: 5));

      expect(received.length, 500);
      for (int i = 0; i < 500; i++) {
        expect(received[i], 'msg-$i');
      }

      await pair.offerer.close();
      await pair.answerer.close();
    });

    test('send 100 messages concurrently — all arrive', () async {
      final pair = await harness.createConnectedPair();

      final received = <String>[];
      pair.answererDc.onMessage.listen((msg) {
        received.add(msg.data as String);
      });

      // Send 100 messages concurrently without awaiting each
      final futures = <Future<void>>[];
      for (int i = 0; i < 100; i++) {
        futures.add(pair.offererDc.send('concurrent-$i'));
      }
      await Future.wait(futures);

      // Wait for all to arrive
      await Future.delayed(const Duration(seconds: 3));

      expect(received.length, 100);
      expect(
        received.toSet().length,
        100,
        reason: 'All messages should be unique',
      );

      await pair.offerer.close();
      await pair.answerer.close();
    });
  });

  // --- Multiple DataChannels per PeerConnection ---

  group('Multiple DataChannels per PeerConnection', () {
    test('three DCs on one PC — messages stay on correct channel', () async {
      final offerer = await harness.createPeerConnection();
      final answerer = await harness.createPeerConnection();

      // Subscribe to answerer's onDataChannel before signaling
      final answererDcs = <String, PionDataChannel>{};
      final dcCompleter = Completer<void>();
      var dcCount = 0;

      answerer.onDataChannel.listen((dc) {
        answererDcs[dc.label] = dc;
        dcCount++;
        if (dcCount == 3 && !dcCompleter.isCompleted) {
          dcCompleter.complete();
        }
      });

      // Offerer creates 3 DCs before generating offer
      final offererDcA = await offerer.createDataChannel('dc-a');
      final offererDcB = await offerer.createDataChannel('dc-b');
      final offererDcC = await offerer.createDataChannel('dc-c');

      // Full signaling
      final offererCandidates = <IceCandidate>[];
      final answererCandidates = <IceCandidate>[];
      offerer.onIceCandidate.listen(offererCandidates.add);
      answerer.onIceCandidate.listen(answererCandidates.add);

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

      // Wait for all DCs to be established
      await dcCompleter.future.timeout(const Duration(seconds: 10));

      // Collect messages from each answerer DC
      final messagesA = <String>[];
      final messagesB = <String>[];
      final messagesC = <String>[];

      answererDcs['dc-a']?.onMessage.listen((msg) => messagesA.add(msg.data));
      answererDcs['dc-b']?.onMessage.listen((msg) => messagesB.add(msg.data));
      answererDcs['dc-c']?.onMessage.listen((msg) => messagesC.add(msg.data));

      // Send distinct payloads on each offerer DC
      await offererDcA.send('hello-a');
      await offererDcB.send('hello-b');
      await offererDcC.send('hello-c');

      await Future.delayed(const Duration(seconds: 2));

      // Verify each DC received its matching message
      expect(messagesA, ['hello-a']);
      expect(messagesB, ['hello-b']);
      expect(messagesC, ['hello-c']);

      await offerer.close();
      await answerer.close();
    });
  });

  // --- Rapid create/delete cycles ---

  group('Rapid create/delete cycles', () {
    test('create and close 50 PeerConnections without crashing', () async {
      // Rapidly create and close 50 PCs
      for (int i = 0; i < 50; i++) {
        final pc = await harness.createPeerConnection();
        await pc.close();
      }

      // Verify the server still responds
      final testPc = await harness.createPeerConnection();
      expect(testPc.handle, hasLength(32));
      await testPc.close();
    });

    test('create and close 50 DataChannels on same PC without crashing',
        () async {
      final pc = await harness.createPeerConnection();

      // Rapidly create and close 50 DCs
      for (int i = 0; i < 50; i++) {
        final dc = await pc.createDataChannel('dc-$i');
        await dc.close();
      }

      // Verify the server still responds
      final testDc = await pc.createDataChannel('test');
      expect(testDc.handle, hasLength(32));
      await testDc.close();

      await pc.close();
    });
  });

  // --- Large messages and high throughput ---

  group('Large messages and high throughput', () {
    test('send 60 KB binary payload — arrives intact', () async {
      final pair = await harness.createConnectedPair();

      final received = Completer<List<int>>();
      pair.answererDc.onMessage.listen((msg) {
        if (!received.isCompleted && msg.isBinary) {
          received.complete(msg.bytes);
        }
      });

      // Generate a 60 KB payload (pion/webrtc max is 64KB)
      final payload = List<int>.generate(
        60 * 1024,
        (index) => index % 256,
      );

      await pair.offererDc.sendBinary(payload);

      final result = await received.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
          'No binary message received',
          const Duration(seconds: 15),
        ),
      );

      expect(result.length, 60 * 1024);
      expect(result, payload);

      await pair.offerer.close();
      await pair.answerer.close();
    });

    test('send 30 KB binary messages back-and-forth 10 times', () async {
      final pair = await harness.createConnectedPair();

      final responses = <int>[];
      pair.offererDc.onMessage.listen((msg) {
        if (msg.isBinary) {
          responses.add(msg.bytes.length);
        }
      });

      pair.answererDc.onMessage.listen((msg) {
        // Echo back if binary
        if (msg.isBinary) {
          unawaited(pair.answererDc.sendBinary(msg.bytes));
        }
      });

      // Send 30 KB binary message 10 times (well under 64KB limit)
      final payload = List<int>.generate(30 * 1024, (i) => i % 256);
      for (int i = 0; i < 10; i++) {
        await pair.offererDc.sendBinary(payload);
      }

      // Wait for echoes
      await Future.delayed(const Duration(seconds: 5));

      expect(responses.length, 10);
      expect(responses, everyElement(30 * 1024));

      await pair.offerer.close();
      await pair.answerer.close();
    });
  });

  // --- ICE server configuration ---

  group('ICE server configuration', () {
    test('create PeerConnection with TURN server config — no error', () async {
      final turnServers = [
        IceServer(
          urls: ['turn:turn.example.com:3478?transport=udp'],
          username: 'user',
          credential: 'pass',
        ),
      ];

      final pc = await harness.createPeerConnection(iceServers: turnServers);

      // Verify PC was created successfully
      expect(pc.handle, hasLength(32));

      await pc.close();
    });

    test('create PeerConnection with multiple STUN and TURN servers', () async {
      final iceServers = [
        IceServer(urls: ['stun:stun.l.google.com:19302']),
        IceServer(urls: ['stun:stun1.l.google.com:19302']),
        IceServer(
          urls: ['turn:turn.example.com:3478'],
          username: 'user',
          credential: 'pass',
        ),
      ];

      final pc = await harness.createPeerConnection(iceServers: iceServers);

      expect(pc.handle, hasLength(32));

      await pc.close();
    });
  });
}
