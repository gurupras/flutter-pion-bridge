// Integration tests for PionSettingsEngine.detachDataChannels, run against BOTH
// transports: the sidecar over a localhost WebSocket, and the in-process shared
// library over dart:ffi. Detaching is a Go-side change — the Dart API must
// behave identically with it on.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/bridge.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/types.dart';

import '../helpers/test_harness.dart';

PionSettingsEngine settings({required bool detach}) => PionSettingsEngine(
      interfaceWhitelist:
          Platform.isWindows ? null : [Platform.isMacOS ? 'lo0' : 'lo'],
      includeLoopbackCandidate: true,
      detachDataChannels: detach,
      enableDataChannelBlockWrite: detach,
      sctpMaxReceiveBufferSize: 8 * 1024 * 1024,
    );

/// Builds the shared library once per test process (see shared_mode_test.dart).
Future<String> _sharedLibrary() async {
  final goDir = '${Directory.current.path}/go';
  final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
  final target = '$goDir/libpionbridge_test.$ext';
  final lock =
      await File('$goDir/.libpionbridge_test.lock').open(mode: FileMode.write);
  await lock.lock(FileLock.blockingExclusive);
  try {
    final tmp = '$goDir/libpionbridge_test_build_$pid.$ext';
    final r = await Process.run('go', ['build', '-buildmode=c-shared', '-o', tmp, './shared'],
        workingDirectory: goDir);
    if (r.exitCode != 0) throw Exception('build failed:\n${r.stderr}');
    final header = File('${tmp.substring(0, tmp.length - ext.length - 1)}.h');
    if (header.existsSync()) header.deleteSync();
    if (File(target).existsSync()) File(target).deleteSync();
    File(tmp).renameSync(target);
  } finally {
    await lock.unlock();
    await lock.close();
  }
  return target;
}

/// Connects two bridges over loopback and returns both ends of one channel.
Future<(PionDataChannel, PionDataChannel)> connectPair(
    PionBridge a, PionBridge b, String label) async {
  final offerer = await a.createPeerConnection();
  final answerer = await b.createPeerConnection();
  offerer.onIceCandidate.listen((c) => answerer.addIceCandidate(c).catchError((_) {}));
  answerer.onIceCandidate.listen((c) => offerer.addIceCandidate(c).catchError((_) {}));

  final remote = Completer<PionDataChannel>();
  answerer.onDataChannel.listen(remote.complete);
  final local = await offerer.createDataChannel(label);
  final opened = local.onOpen.first;

  final offer = await offerer.createOffer();
  await offerer.setLocalDescription(offer, 'offer');
  await answerer.setRemoteDescription(offer, 'offer');
  final answer = await answerer.createAnswer();
  await answerer.setLocalDescription(answer, 'answer');
  await offerer.setRemoteDescription(answer, 'answer');

  await opened.timeout(const Duration(seconds: 30));
  return (local, await remote.future.timeout(const Duration(seconds: 30)));
}

void main() {
  late TestHarness harness;
  late String lib;

  setUpAll(() async {
    await TestHarness.ensureBinary();
    lib = await _sharedLibrary();
  });
  tearDownAll(() => TestHarness.cleanupBinary());
  setUp(() async {
    harness = TestHarness();
    await harness.start();
  });
  tearDown(() async => harness.stop());

  Future<PionBridge> websocket({required bool detach}) => PionBridge.connectExisting(
        PionServerEndpoint(port: harness.port, token: harness.token),
        settingsEngine: settings(detach: detach),
      );
  Future<PionBridge> shared({required bool detach}) => PionBridge.initialize(
        mode: PionBridgeMode.shared,
        sharedLibraryPath: lib,
        settingsEngine: settings(detach: detach),
      );

  for (final mode in ['websocket', 'shared']) {
    Future<PionBridge> open({bool detach = true}) =>
        mode == 'websocket' ? websocket(detach: detach) : shared(detach: detach);

    group('detached data channels ($mode)', () {
      test('carry text and binary both ways, including a large message', () async {
        final a = await open(), b = await open();
        try {
          final (local, remote) = await connectPair(a, b, 'bulk');
          final atRemote = remote.onMessage.take(2).toList();

          await local.send('hello detached');
          // Larger than the Go read loop's initial 64 KB buffer.
          final big = Uint8List.fromList(List.generate(300000, (i) => i & 0xff));
          await local.sendBinary(big);

          final got = await atRemote.timeout(const Duration(seconds: 60));
          expect(got[0].isBinary, isFalse);
          expect(got[0].text, 'hello detached');
          expect(got[1].isBinary, isTrue);
          expect(got[1].bytes, big);

          // ... and the remote end can send back.
          final atLocal = local.onMessage.first;
          await remote.send('reply');
          expect((await atLocal.timeout(const Duration(seconds: 30))).text, 'reply');
        } finally {
          await a.close();
          await b.close();
        }
      });

      test('a burst of messages arrives complete and in order', () async {
        final a = await open(), b = await open();
        try {
          final (local, remote) = await connectPair(a, b, 'burst');
          const n = 50;
          final received = remote.onMessage.take(n).toList();
          for (var i = 0; i < n; i++) {
            final payload = Uint8List(64 * 1024)..[0] = i;
            await local.sendBinary(payload, awaitDrain: false);
          }
          final got = await received.timeout(const Duration(seconds: 60));
          for (var i = 0; i < n; i++) {
            expect(got[i].bytes.length, 64 * 1024);
            expect(got[i].bytes[0], i, reason: 'message $i out of order');
          }
        } finally {
          await a.close();
          await b.close();
        }
      });

      // Detaching removes the channel from pion's close notifications, so the
      // bridge reports the close from its own read loop. (close() disposes the
      // local end's streams first, by design, so only the remote end observes
      // onClose — the same as without detaching.)
      test('closing reports onClose on the remote end', () async {
        final a = await open(), b = await open();
        try {
          final (local, remote) = await connectPair(a, b, 'closing');
          final remoteClosed = remote.onClose.first;
          await local.close();
          await remoteClosed.timeout(const Duration(seconds: 30));
        } finally {
          await a.close();
          await b.close();
        }
      });
    });
  }
}
