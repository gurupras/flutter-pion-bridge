// Tests that PionBridge is accessible and functional from Dart isolates.
//
// Key design constraints:
//   - Object instances (WebSocketConnection, PionPeerConnection, …) cannot cross
//     isolate boundaries.  Each isolate must create its own instances.
//   - The Go server's registry is shared across all WebSocket connections, so a
//     resource handle created in isolate A can be operated on by isolate B.
//   - Events for a resource are sent back to the WebSocket connection that
//     *created* that resource.  Closing a connection does not destroy the
//     underlying WebRTC objects — they remain in the registry until explicitly
//     deleted or until the 5-minute cleanup fires.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:pion_bridge/src/event_dispatcher.dart';
import 'package:pion_bridge/src/peer_connection.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';

import '../helpers/test_harness.dart';

// ---------------------------------------------------------------------------
// Library-level helpers — usable inside isolate entry points because they
// are top-level functions with no captured state.
// ---------------------------------------------------------------------------

Future<(WebSocketConnection, EventDispatcher)> _connect(
    int port, String token) async {
  final dispatcher = EventDispatcher();
  final conn = WebSocketConnection(onMessage: dispatcher.broadcast);
  await conn.connect('ws://127.0.0.1:$port/', token: token);
  return (conn, dispatcher);
}

Future<PionPeerConnection> _createPC(
    WebSocketConnection conn, EventDispatcher disp) async {
  final resp = await conn.request('pc:create', null, {
    'ice_servers': [],
    'bundle_policy': 'balanced',
    'rtcp_mux_policy': 'require',
  });
  return PionPeerConnection(resp['handle'] as String, conn, disp);
}

// ---------------------------------------------------------------------------

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

  group('Isolate access', () {
    // -----------------------------------------------------------------------
    // 1. Basic connectivity
    // -----------------------------------------------------------------------

    test('spawned isolate can connect to server and receive init:ack', () async {
      final recv = ReceivePort();
      await Isolate.spawn(_test1IsolateMain, recv.sendPort);
      final iter = StreamIterator(recv);

      await iter.moveNext();
      (iter.current as SendPort).send({'port': harness.port, 'token': harness.token});

      await iter.moveNext();
      final version = iter.current as String;
      recv.close();

      expect(version, '1.0.0');
    });

    // -----------------------------------------------------------------------
    // 2. PeerConnection operations from an isolate
    // -----------------------------------------------------------------------

    test('spawned isolate can create a PeerConnection and generate an offer',
        () async {
      final recv = ReceivePort();
      await Isolate.spawn(_test2IsolateMain, recv.sendPort);
      final iter = StreamIterator(recv);

      await iter.moveNext();
      (iter.current as SendPort).send({'port': harness.port, 'token': harness.token});

      await iter.moveNext();
      final result = iter.current as Map;
      recv.close();

      expect(result['handle'] as String, hasLength(32));
      expect(result['sdp'] as String, contains('v=0'));
    });

    // -----------------------------------------------------------------------
    // 3. Full WebRTC handshake inside a single spawned isolate
    // -----------------------------------------------------------------------

    test('full offer/answer/ICE flow runs correctly inside a spawned isolate',
        () async {
      final recv = ReceivePort();
      await Isolate.spawn(_test3IsolateMain, recv.sendPort);
      final iter = StreamIterator(recv);

      await iter.moveNext();
      (iter.current as SendPort).send({'port': harness.port, 'token': harness.token});

      await iter.moveNext();
      final bothConnected = iter.current as bool;
      recv.close();

      expect(bothConnected, isTrue);
    });

    // -----------------------------------------------------------------------
    // 4. DataChannel message from a spawned isolate received in the main isolate
    //
    // Flow:
    //   Main (connection A) owns the offerer PC + DC.
    //   Events for the offerer's DC → connection A → main isolate.
    //
    //   Phase 1  Main creates offerer + DC, generates offer + ICE candidates.
    //   Phase 2  Spawned isolate (connection B) creates answerer.  To avoid a
    //            deadlock it sends answer + candidates first, then waits for
    //            onDataChannel (which fires only after main adds those candidates).
    //   Phase 3  Main sets remote desc + adds answerer candidates.
    //   Phase 4  Main waits for the offerer's DC to open.
    //   Phase 5  Main receives the answerer's DC handle (sent after onDataChannel).
    //   Phase 6  A second spawned isolate (connection C) calls dc:send on the
    //            answerer's DC handle.  The message travels over WebRTC to the
    //            offerer's DC, whose event:dataChannelMessage arrives on conn A.
    //   Phase 7  Main asserts the received text.
    // -----------------------------------------------------------------------

    test(
        'DataChannel message sent from a spawned isolate is received in the main isolate',
        () async {
      // --- Phase 1: main creates offerer resources. ---

      final offerer = await harness.createPeerConnection();
      final offererDc = await offerer.createDataChannel('cross-isolate');

      final receivedCompleter = Completer<String>();
      offererDc.onMessage.listen((msg) {
        if (!receivedCompleter.isCompleted) receivedCompleter.complete(msg.text);
      });

      final dcOpenCompleter = Completer<void>();
      offererDc.onOpen.listen((_) {
        if (!dcOpenCompleter.isCompleted) dcOpenCompleter.complete();
      });

      final offererCandidates = <IceCandidate>[];
      offerer.onIceCandidate.listen(offererCandidates.add);

      final offer = await offerer.createOffer();
      await offerer.setLocalDescription(offer, 'offer');
      await Future.delayed(const Duration(seconds: 1));

      final offerCandidateMaps = offererCandidates
          .map((c) => <String, dynamic>{
                'candidate': c.candidate,
                'sdp_mid': c.sdpMid,
                'sdp_mline_index': c.sdpMlineIndex,
              })
          .toList();

      // --- Phase 2: spawn answerer isolate. ---
      //
      // The answerer sends {answerSdp, answererCandidates} first, then
      // (after main completes ICE) sends {dcHandle}.

      final answererRecv = ReceivePort();
      await Isolate.spawn(_test4AnswererMain, answererRecv.sendPort);
      final answererIter = StreamIterator(answererRecv);

      await answererIter.moveNext();
      (answererIter.current as SendPort).send({
        'port': harness.port,
        'token': harness.token,
        'offerSdp': offer,
        'offerCandidates': offerCandidateMaps,
      });

      await answererIter.moveNext();
      final signalingPayload = answererIter.current as Map;
      final answerSdp = signalingPayload['answerSdp'] as String;
      final answererCandidateMaps =
          (signalingPayload['answererCandidates'] as List)
              .cast<Map<String, dynamic>>();

      // --- Phase 3: main completes ICE. ---

      await offerer.setRemoteDescription(answerSdp, 'answer');
      for (final c in answererCandidateMaps) {
        await offerer.addIceCandidate(IceCandidate(
          candidate: c['candidate'] as String,
          sdpMid: c['sdp_mid'] as String,
          sdpMlineIndex: c['sdp_mline_index'] as int,
        ));
      }

      // --- Phase 4: wait for the offerer's DC to open. ---

      await dcOpenCompleter.future.timeout(const Duration(seconds: 10));

      // --- Phase 5: receive answerer's DC handle (sent after onDataChannel). ---

      await answererIter.moveNext();
      final dcHandlePayload = answererIter.current as Map;
      final answererDcHandle = dcHandlePayload['dcHandle'] as String;
      answererRecv.close();

      // --- Phase 6: fresh spawned isolate sends on the answerer's DC. ---

      final senderRecv = ReceivePort();
      await Isolate.spawn(_test4SenderMain, senderRecv.sendPort);
      final senderIter = StreamIterator(senderRecv);

      await senderIter.moveNext();
      (senderIter.current as SendPort).send({
        'port': harness.port,
        'token': harness.token,
        'dcHandle': answererDcHandle,
      });

      await senderIter.moveNext(); // 'done'
      senderRecv.close();

      // --- Phase 7: verify. ---

      final received =
          await receivedCompleter.future.timeout(const Duration(seconds: 5));
      expect(received, 'hello from isolate');
    });

    // -----------------------------------------------------------------------
    // 5. Two spawned isolates exchange DataChannel messages via the server
    //
    // Both isolates are active simultaneously via Isolate.spawn.  The main
    // test body acts as coordinator for the SDP/ICE exchange, then signals
    // each isolate to proceed.  The message payload flows entirely through
    // the Go WebRTC server — no Dart SendPort carries it.
    //
    // Deadlock note: the answerer sends {sdp, candidates} to coordinator
    // *before* waiting for onDataChannel.  That event only fires once the
    // offerer has those candidates and ICE completes.  Waiting first would
    // create a circular dependency.
    // -----------------------------------------------------------------------

    test('two spawned isolates exchange DataChannel messages', () async {
      final portNum = harness.port;
      final tokenStr = harness.token;

      // --- Spawn the offerer isolate. ---

      final offererPort = ReceivePort();
      late SendPort offererSend;

      await Isolate.spawn(_offererIsolateMain, offererPort.sendPort);
      final offererMessages = StreamIterator(offererPort);

      await offererMessages.moveNext();
      offererSend = offererMessages.current as SendPort;
      offererSend.send({'serverPort': portNum, 'token': tokenStr});

      await offererMessages.moveNext();
      final offerPayload = offererMessages.current as Map;
      final offerSdp = offerPayload['sdp'] as String;
      final offererCandidateMaps =
          (offerPayload['candidates'] as List).cast<Map>();

      // --- Spawn the answerer isolate. ---

      final answererPort = ReceivePort();
      late SendPort answererSend;

      await Isolate.spawn(_answererIsolateMain, answererPort.sendPort);
      final answererMessages = StreamIterator(answererPort);

      await answererMessages.moveNext();
      answererSend = answererMessages.current as SendPort;

      answererSend.send({
        'serverPort': portNum,
        'token': tokenStr,
        'offerSdp': offerSdp,
        'offererCandidates': offererCandidateMaps
            .map((m) => Map<String, dynamic>.from(m))
            .toList(),
      });

      // Receive answer + candidates (answerer sends these before waiting for
      // onDataChannel, to avoid the circular dependency described above).
      await answererMessages.moveNext();
      final answerPayload = answererMessages.current as Map;
      final answerSdp = answerPayload['sdp'] as String;
      final answererCandidateMaps =
          (answerPayload['candidates'] as List).cast<Map>();

      // Forward the answer to the offerer isolate so it can complete ICE.
      offererSend.send({
        'answerSdp': answerSdp,
        'answererCandidates': answererCandidateMaps
            .map((m) => Map<String, dynamic>.from(m))
            .toList(),
      });

      // Wait for the offerer to signal "DC is open and I'm ready".
      await offererMessages.moveNext();
      expect(offererMessages.current, 'ready');

      // Signal the answerer to send a DC message.
      answererSend.send('send');

      // The offerer isolate reports the received text.
      await offererMessages.moveNext();
      final received = offererMessages.current as String;

      // Clean up.
      offererSend.send('done');
      answererSend.send('done');
      offererPort.close();
      answererPort.close();

      expect(received, 'hello from answerer isolate');
    });
  });
}

// ---------------------------------------------------------------------------
// Top-level isolate entry points
// ---------------------------------------------------------------------------

// --- Test 1 ---

Future<void> _test1IsolateMain(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);
  final msgs = StreamIterator(myPort);

  await msgs.moveNext();
  final init = msgs.current as Map;

  final conn = WebSocketConnection(onMessage: (_) {});
  await conn.connect('ws://127.0.0.1:${init['port']}/', token: init['token'] as String);
  final resp = await conn.request('init', null, {});
  await conn.close();
  myPort.close();

  coordinator.send(resp['version'] as String);
}

// --- Test 2 ---

Future<void> _test2IsolateMain(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);
  final msgs = StreamIterator(myPort);

  await msgs.moveNext();
  final init = msgs.current as Map;

  final (conn, disp) =
      await _connect(init['port'] as int, init['token'] as String);
  final pc = await _createPC(conn, disp);
  await pc.createDataChannel('test');
  final sdp = await pc.createOffer();
  final handle = pc.handle;
  await conn.close();
  myPort.close();

  coordinator.send({'handle': handle, 'sdp': sdp});
}

// --- Test 3 ---

Future<void> _test3IsolateMain(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);
  final msgs = StreamIterator(myPort);

  await msgs.moveNext();
  final init = msgs.current as Map;

  final (conn, disp) =
      await _connect(init['port'] as int, init['token'] as String);

  final offerer = await _createPC(conn, disp);
  final answerer = await _createPC(conn, disp);

  final offererStates = <ConnectionState>[];
  final answererStates = <ConnectionState>[];
  offerer.onConnectionStateChange.listen(offererStates.add);
  answerer.onConnectionStateChange.listen(answererStates.add);

  final offererCandidates = <IceCandidate>[];
  final answererCandidates = <IceCandidate>[];
  offerer.onIceCandidate.listen(offererCandidates.add);
  answerer.onIceCandidate.listen(answererCandidates.add);

  await offerer.createDataChannel('chat');

  final offer = await offerer.createOffer();
  await offerer.setLocalDescription(offer, 'offer');
  await answerer.setRemoteDescription(offer, 'offer');

  final answer = await answerer.createAnswer();
  await answerer.setLocalDescription(answer, 'answer');
  await offerer.setRemoteDescription(answer, 'answer');

  await Future.delayed(const Duration(seconds: 1));

  for (final c in List.of(offererCandidates)) {
    await answerer.addIceCandidate(c);
  }
  for (final c in List.of(answererCandidates)) {
    await offerer.addIceCandidate(c);
  }

  await Future.delayed(const Duration(seconds: 3));
  await conn.close();
  myPort.close();

  coordinator.send(offererStates.contains(ConnectionState.connected) &&
      answererStates.contains(ConnectionState.connected));
}

// --- Test 4: answerer isolate ---
//
// Sends {answerSdp, answererCandidates} to coordinator FIRST (so coordinator
// can complete ICE on the offerer), then waits for onDataChannel (which only
// fires once ICE completes), then sends {dcHandle}.

Future<void> _test4AnswererMain(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);
  final msgs = StreamIterator(myPort);

  await msgs.moveNext();
  final init = msgs.current as Map;

  final portNum = init['port'] as int;
  final tokenStr = init['token'] as String;
  final offerSdp = init['offerSdp'] as String;
  final offerCandidates = (init['offerCandidates'] as List).cast<Map>();

  final (conn, disp) = await _connect(portNum, tokenStr);
  final answerer = await _createPC(conn, disp);

  final candidateMaps = <Map<String, dynamic>>[];
  final dcHandleCompleter = Completer<String>();

  answerer.onIceCandidate.listen((c) => candidateMaps.add(<String, dynamic>{
        'candidate': c.candidate,
        'sdp_mid': c.sdpMid,
        'sdp_mline_index': c.sdpMlineIndex,
      }));

  answerer.onDataChannel.listen((dc) {
    if (!dcHandleCompleter.isCompleted) dcHandleCompleter.complete(dc.handle);
  });

  await answerer.setRemoteDescription(offerSdp, 'offer');
  final answer = await answerer.createAnswer();
  await answerer.setLocalDescription(answer, 'answer');

  for (final c in offerCandidates) {
    await answerer.addIceCandidate(IceCandidate(
      candidate: c['candidate'] as String,
      sdpMid: c['sdp_mid'] as String,
      sdpMlineIndex: c['sdp_mline_index'] as int,
    ));
  }

  await Future.delayed(const Duration(seconds: 1));

  // Send answer + candidates before waiting for onDataChannel.
  // If we waited first we would deadlock: onDataChannel only fires after
  // the offerer (main) adds our candidates, which it can't do until we send.
  coordinator.send({
    'answerSdp': answer,
    'answererCandidates': List<Map<String, dynamic>>.from(candidateMaps),
  });

  // Now wait for the DC to open (coordinator is adding our candidates above).
  final dcHandle =
      await dcHandleCompleter.future.timeout(const Duration(seconds: 20));

  await conn.close();
  myPort.close();

  coordinator.send({'dcHandle': dcHandle});
}

// --- Test 4: sender isolate ---

Future<void> _test4SenderMain(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);
  final msgs = StreamIterator(myPort);

  await msgs.moveNext();
  final init = msgs.current as Map;

  final portNum = init['port'] as int;
  final tokenStr = init['token'] as String;
  final dcHandle = init['dcHandle'] as String;

  final conn = WebSocketConnection(onMessage: (_) {});
  await conn.connect('ws://127.0.0.1:$portNum/', token: tokenStr);
  conn.send('dc:send', dcHandle, <String, dynamic>{
    'data': 'hello from isolate',
    'is_binary': false,
  });
  await Future.delayed(const Duration(milliseconds: 200));
  await conn.close();
  myPort.close();

  coordinator.send('done');
}

// ---------------------------------------------------------------------------
// Test 5 isolate entry points
// ---------------------------------------------------------------------------

/// Offerer isolate: creates the offerer PC + DC, drives half the signaling,
/// waits for the DC to open, then listens for a single DataChannel message
/// and reports it back to the coordinator.
Future<void> _offererIsolateMain(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);

  final messages = StreamIterator(myPort);

  await messages.moveNext();
  final init = messages.current as Map;
  final portNum = init['serverPort'] as int;
  final tokenStr = init['token'] as String;

  final (conn, disp) = await _connect(portNum, tokenStr);
  final offerer = await _createPC(conn, disp);

  final candidateMaps = <Map<String, dynamic>>[];
  final dcOpenCompleter = Completer<void>();
  final messageCompleter = Completer<String>();

  offerer.onIceCandidate.listen((c) => candidateMaps.add(<String, dynamic>{
        'candidate': c.candidate,
        'sdp_mid': c.sdpMid,
        'sdp_mline_index': c.sdpMlineIndex,
      }));

  final dc = await offerer.createDataChannel('two-isolate');

  dc.onOpen.listen((_) {
    if (!dcOpenCompleter.isCompleted) dcOpenCompleter.complete();
  });

  dc.onMessage.listen((msg) {
    if (!messageCompleter.isCompleted) messageCompleter.complete(msg.text);
  });

  final offer = await offerer.createOffer();
  await offerer.setLocalDescription(offer, 'offer');

  await Future.delayed(const Duration(seconds: 1));

  coordinator.send({
    'sdp': offer,
    'candidates': List<Map<String, dynamic>>.from(candidateMaps),
  });

  await messages.moveNext();
  final answerPayload = messages.current as Map;
  final answerSdp = answerPayload['answerSdp'] as String;
  final answererCandidates =
      (answerPayload['answererCandidates'] as List).cast<Map>();

  await offerer.setRemoteDescription(answerSdp, 'answer');
  for (final c in answererCandidates) {
    await offerer.addIceCandidate(IceCandidate(
      candidate: c['candidate'] as String,
      sdpMid: c['sdp_mid'] as String,
      sdpMlineIndex: c['sdp_mline_index'] as int,
    ));
  }

  await dcOpenCompleter.future.timeout(const Duration(seconds: 10));
  coordinator.send('ready');

  final text =
      await messageCompleter.future.timeout(const Duration(seconds: 10));
  coordinator.send(text);

  await messages.moveNext(); // 'done'
  await conn.close();
  myPort.close();
}

/// Answerer isolate: creates the answerer PC, completes signaling.
///
/// Sends {sdp, candidates} to coordinator BEFORE waiting for onDataChannel
/// to avoid a circular dependency: onDataChannel only fires once the offerer
/// has processed our candidates and ICE has completed, but the offerer only
/// gets those candidates after we send them to the coordinator.
Future<void> _answererIsolateMain(SendPort coordinator) async {
  final myPort = ReceivePort();
  coordinator.send(myPort.sendPort);

  final messages = StreamIterator(myPort);

  await messages.moveNext();
  final init = messages.current as Map;
  final portNum = init['serverPort'] as int;
  final tokenStr = init['token'] as String;
  final offerSdp = init['offerSdp'] as String;
  final offererCandidates = (init['offererCandidates'] as List).cast<Map>();

  final (conn, disp) = await _connect(portNum, tokenStr);
  final answerer = await _createPC(conn, disp);

  final candidateMaps = <Map<String, dynamic>>[];
  final dcHandleCompleter = Completer<String>();

  answerer.onIceCandidate.listen((c) => candidateMaps.add(<String, dynamic>{
        'candidate': c.candidate,
        'sdp_mid': c.sdpMid,
        'sdp_mline_index': c.sdpMlineIndex,
      }));

  answerer.onDataChannel.listen((dc) {
    if (!dcHandleCompleter.isCompleted) dcHandleCompleter.complete(dc.handle);
  });

  await answerer.setRemoteDescription(offerSdp, 'offer');
  final answer = await answerer.createAnswer();
  await answerer.setLocalDescription(answer, 'answer');

  for (final c in offererCandidates) {
    await answerer.addIceCandidate(IceCandidate(
      candidate: c['candidate'] as String,
      sdpMid: c['sdp_mid'] as String,
      sdpMlineIndex: c['sdp_mline_index'] as int,
    ));
  }

  await Future.delayed(const Duration(seconds: 1));

  // Send answer + candidates to coordinator BEFORE waiting for onDataChannel.
  coordinator.send({
    'sdp': answer,
    'candidates': List<Map<String, dynamic>>.from(candidateMaps),
  });

  // Wait for ICE to complete and the remote DC to be established.
  final dcHandle =
      await dcHandleCompleter.future.timeout(const Duration(seconds: 20));

  // Wait for coordinator's 'send' signal.
  await messages.moveNext();
  if (messages.current == 'send') {
    conn.send('dc:send', dcHandle, <String, dynamic>{
      'data': 'hello from answerer isolate',
      'is_binary': false,
    });
    await Future.delayed(const Duration(milliseconds: 200));
  }

  await messages.moveNext(); // 'done'
  await conn.close();
  myPort.close();
}
