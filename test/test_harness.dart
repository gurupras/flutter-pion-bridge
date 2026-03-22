import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/event_dispatcher.dart';
import 'package:pion_bridge/src/peer_connection.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';

/// Test harness that builds the Go server binary, starts it as a subprocess,
/// and provides a connected WebSocketConnection for testing.
class TestHarness {
  static String? _binaryPath;
  Process? _process;
  late WebSocketConnection connection;
  late EventDispatcher dispatcher;
  late int port;
  late String token;
  bool _disconnected = false;

  bool get disconnected => _disconnected;

  /// Build the Go binary once per test run.
  static Future<void> ensureBinary() async {
    if (_binaryPath != null && File(_binaryPath!).existsSync()) return;

    final goDir = '${Directory.current.path}/go';
    _binaryPath = '$goDir/pionbridge_test_bin';

    final result = await Process.run(
      'go',
      ['build', '-o', _binaryPath!, '.'],
      workingDirectory: goDir,
    );
    if (result.exitCode != 0) {
      throw Exception('Failed to build Go binary:\n${result.stderr}');
    }
  }

  /// Start the Go server and connect.
  Future<void> start() async {
    await ensureBinary();

    _process = await Process.start(_binaryPath!, []);

    // Read the startup JSON from stdout (first line)
    final stdoutLine = await _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;

    final startup = jsonDecode(stdoutLine) as Map<String, dynamic>;
    port = startup['port'] as int;
    token = startup['token'] as String;

    dispatcher = EventDispatcher();
    connection = WebSocketConnection(
      onMessage: dispatcher.broadcast,
      onDisconnect: () {
        _disconnected = true;
      },
    );

    await connection.connect(
      'ws://127.0.0.1:$port/',
      token: token,
    );
  }

  /// Create a PeerConnection through the connection directly.
  Future<PionPeerConnection> createPeerConnection({
    List<IceServer>? iceServers,
  }) async {
    final response = await connection.request('pc:create', null, {
      'ice_servers': iceServers?.map((s) => s.toMap()).toList() ?? [],
      'bundle_policy': 'balanced',
      'rtcp_mux_policy': 'require',
    });

    return PionPeerConnection(
      response['handle'] as String,
      connection,
      dispatcher,
    );
  }

  /// Stop the Go server.
  Future<void> stop() async {
    try {
      await connection.close();
    } catch (_) {}
    _process?.kill();
    await _process?.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process?.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    _process = null;
  }

  /// Kill the server abruptly (for disconnect tests).
  void kill() {
    _process?.kill(ProcessSignal.sigkill);
    _process = null;
  }

  /// Create a fully connected pair of PeerConnections with a DataChannel.
  /// Returns (offerer, answerer, offererDC).
  /// The answerer's DC can be obtained via answerer.onDataChannel.
  Future<ConnectedPair> createConnectedPair() async {
    final offerer = await createPeerConnection();
    final answerer = await createPeerConnection();

    // Subscribe to ICE candidates before signaling
    final offererCandidates = <IceCandidate>[];
    final answererCandidates = <IceCandidate>[];
    offerer.onIceCandidate.listen(offererCandidates.add);
    answerer.onIceCandidate.listen(answererCandidates.add);

    // Subscribe to answerer's onDataChannel before signaling
    final answererDcCompleter = Completer<PionDataChannel>();
    answerer.onDataChannel.listen((dc) {
      if (!answererDcCompleter.isCompleted) {
        answererDcCompleter.complete(dc);
      }
    });

    // Create DC on offerer before offer
    final offererDc = await offerer.createDataChannel('test');

    // Signaling
    final offer = await offerer.createOffer();
    await offerer.setLocalDescription(offer, 'offer');
    await answerer.setRemoteDescription(offer, 'offer');

    final answer = await answerer.createAnswer();
    await answerer.setLocalDescription(answer, 'answer');
    await offerer.setRemoteDescription(answer, 'answer');

    // Wait for ICE gathering
    await Future.delayed(const Duration(seconds: 1));

    // Exchange ICE candidates
    for (final c in offererCandidates) {
      await answerer.addIceCandidate(c);
    }
    for (final c in answererCandidates) {
      await offerer.addIceCandidate(c);
    }

    // Wait for connection + SCTP to establish
    await Future.delayed(const Duration(seconds: 2));

    // Get answerer's DC
    final answererDc = await answererDcCompleter.future
        .timeout(const Duration(seconds: 5));

    return ConnectedPair(
      offerer: offerer,
      answerer: answerer,
      offererDc: offererDc,
      answererDc: answererDc,
    );
  }

  /// Clean up the binary after all tests.
  static void cleanupBinary() {
    if (_binaryPath != null) {
      try {
        File(_binaryPath!).deleteSync();
      } catch (_) {}
    }
  }
}

class ConnectedPair {
  final PionPeerConnection offerer;
  final PionPeerConnection answerer;
  final PionDataChannel offererDc;
  final PionDataChannel answererDc;

  ConnectedPair({
    required this.offerer,
    required this.answerer,
    required this.offererDc,
    required this.answererDc,
  });
}
