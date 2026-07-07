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

  /// Build the Go binary once per test PROCESS.
  ///
  /// `flutter test` runs each test file in its own process, so this static is
  /// not shared across files and several builds can run concurrently. Two
  /// things make that safe here:
  ///  - builds are serialized with an exclusive file lock, and
  ///  - the binary is built to a temp path and atomically rename()d over the
  ///    target, so another file's Process.start never sees a partially
  ///    written binary (ETXTBSY) or a missing one (ENOENT). A rename swaps
  ///    the inode; already-running servers are unaffected.
  static Future<void> ensureBinary() async {
    if (_binaryPath != null) return;

    final goDir = '${Directory.current.path}/go';
    final target = '$goDir/pionbridge_test_bin';

    final lockFile =
        await File('$goDir/.pionbridge_test_bin.lock').open(mode: FileMode.write);
    await lockFile.lock(FileLock.blockingExclusive);
    try {
      final tmp = '$target.build.$pid';
      final result = await Process.run(
        'go',
        ['build', '-o', tmp, '.'],
        workingDirectory: goDir,
      );
      if (result.exitCode != 0) {
        throw Exception('Failed to build Go binary:\n${result.stderr}');
      }
      File(tmp).renameSync(target);
    } finally {
      await lockFile.unlock();
      await lockFile.close();
    }
    _binaryPath = target;
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

    // Loopback-only ICE: test peers live in the same process, so host
    // candidates on 127.0.0.1 are all they need. Gathering on every
    // interface makes connection setup slow and flaky on multi-interface
    // hosts (Docker/libvirt bridges).
    await connection.request('init', null, {
      'settings_engine': {
        'interface_whitelist': ['lo'],
        'include_loopback_candidate': true,
      },
    });
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

    // Trickle ICE: forward candidates to the other side as they are
    // gathered. A fixed gather-sleep followed by a one-shot exchange was
    // flaky on hosts with many network interfaces (Docker/libvirt bridges),
    // where gathering outlives the sleep and half the candidates were never
    // exchanged. Late candidates (after the pair connects or a test ends)
    // are forwarded best-effort and errors ignored.
    offerer.onIceCandidate.listen((c) {
      answerer.addIceCandidate(c).catchError((_) {});
    });
    answerer.onIceCandidate.listen((c) {
      offerer.addIceCandidate(c).catchError((_) {});
    });

    // Subscribe to answerer's onDataChannel before signaling
    final answererDcCompleter = Completer<PionDataChannel>();
    answerer.onDataChannel.listen((dc) {
      if (!answererDcCompleter.isCompleted) {
        answererDcCompleter.complete(dc);
      }
    });

    // Create DC on offerer before offer, and watch for it to open — that is
    // the real "connected" signal (ICE + DTLS + SCTP all established).
    final offererDc = await offerer.createDataChannel('test');
    final offererOpen = offererDc.onOpen.first;

    // Signaling
    final offer = await offerer.createOffer();
    await offerer.setLocalDescription(offer, 'offer');
    await answerer.setRemoteDescription(offer, 'offer');

    final answer = await answerer.createAnswer();
    await answerer.setLocalDescription(answer, 'answer');
    await offerer.setRemoteDescription(answer, 'answer');

    // Wait for the channel to actually open on both sides instead of
    // sleeping for a fixed interval.
    await offererOpen.timeout(const Duration(seconds: 30));
    final answererDc = await answererDcCompleter.future
        .timeout(const Duration(seconds: 30));

    return ConnectedPair(
      offerer: offerer,
      answerer: answerer,
      offererDc: offererDc,
      answererDc: answererDc,
    );
  }

  /// Retained for the per-file tearDownAll call sites; intentionally does
  /// NOT delete the binary. Test files run in separate processes, and one
  /// file finishing (and deleting) while another was still spawning servers
  /// produced ENOENT mid-run. The binary is a gitignored build artifact;
  /// ensureBinary rebuilds it (cheap, go build cache) on every test process.
  static void cleanupBinary() {}
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
