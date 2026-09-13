// Integration tests for PionBridgeMode.shared: the Go bridge built as a shared
// library, loaded into the test process with dart:ffi. No sidecar process and
// no WebSocket — frames go through PionBridgeOpen/Send/Close.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/bridge.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/types.dart';

const _loopback = PionSettingsEngine(
  interfaceWhitelist: ['lo'],
  includeLoopbackCandidate: true,
);

/// Builds go/shared once per test process (serialized across processes with a
/// file lock, installed with an atomic rename, like TestHarness.ensureBinary).
Future<String> _ensureSharedLibrary() async {
  final goDir = '${Directory.current.path}/go';
  final target = '$goDir/libpionbridge_test.so';
  final lock = await File('$goDir/.libpionbridge_test.lock')
      .open(mode: FileMode.write);
  await lock.lock(FileLock.blockingExclusive);
  try {
    final tmp = '$target.build.$pid.so';
    final result = await Process.run(
      'go',
      ['build', '-buildmode=c-shared', '-o', tmp, './shared'],
      workingDirectory: goDir,
    );
    if (result.exitCode != 0) {
      throw Exception('Failed to build shared library:\n${result.stderr}');
    }
    File('${tmp.substring(0, tmp.length - 3)}.h').deleteSync();
    File(tmp).renameSync(target);
  } finally {
    await lock.unlock();
    await lock.close();
  }
  return target;
}

Future<PionBridge> _shared(String lib, {void Function()? onDisconnected}) =>
    PionBridge.initialize(
      mode: PionBridgeMode.shared,
      sharedLibraryPath: lib,
      settingsEngine: _loopback,
      onDisconnected: onDisconnected,
    );

void main() {
  late String lib;

  setUpAll(() async {
    lib = await _ensureSharedLibrary();
  });

  group('PionBridgeMode.shared', () {
    test('initializes in-process, reports mode, and closes', () async {
      var disconnected = 0;
      final pion = await _shared(lib, onDisconnected: () => disconnected++);
      expect(pion.mode, PionBridgeMode.shared);
      expect(pion.isConnected, isTrue);

      final pc = await pion.createPeerConnection();
      expect(pc.handle, hasLength(32));

      await pion.close();
      expect(pion.isConnected, isFalse);
      expect(disconnected, 1);
      await pion.close(); // idempotent
      expect(disconnected, 1);
    });

    test('requests after close fail with CONNECTION_LOST', () async {
      final pion = await _shared(lib);
      await pion.close();
      expect(
        () => pion.createPeerConnection(),
        throwsA(isA<PionException>()
            .having((e) => e.code, 'code', 'CONNECTION_LOST')),
      );
    });

    test('a missing library fails with SERVER_START_FAILED', () async {
      expect(
        () => PionBridge.initialize(
          mode: PionBridgeMode.shared,
          sharedLibraryPath: '/nonexistent/libpionbridge.so',
        ),
        throwsA(isA<PionException>()
            .having((e) => e.code, 'code', 'SERVER_START_FAILED')),
      );
    });

    test('two bridges in one process connect a DataChannel and exchange '
        'text and binary both ways', () async {
      // Two sessions on the one in-process server, like two WebSocket
      // connections to one sidecar.
      final a = await _shared(lib);
      final b = await _shared(lib);
      try {
        final offerer = await a.createPeerConnection();
        final answerer = await b.createPeerConnection();
        offerer.onIceCandidate.listen(
            (c) => answerer.addIceCandidate(c).catchError((_) {}));
        answerer.onIceCandidate.listen(
            (c) => offerer.addIceCandidate(c).catchError((_) {}));

        final remote = Completer<PionDataChannel>();
        answerer.onDataChannel.listen(remote.complete);

        final dcA = await offerer.createDataChannel('shared');
        final opened = dcA.onOpen.first;

        final offer = await offerer.createOffer();
        await offerer.setLocalDescription(offer, 'offer');
        await answerer.setRemoteDescription(offer, 'offer');
        final answer = await answerer.createAnswer();
        await answerer.setLocalDescription(answer, 'answer');
        await offerer.setRemoteDescription(answer, 'answer');

        await opened.timeout(const Duration(seconds: 30));
        final dcB = await remote.future.timeout(const Duration(seconds: 30));
        expect(dcB.label, 'shared');

        final atB = dcB.onMessage.take(2).toList();
        await dcA.send('hello from a');
        final payload = Uint8List.fromList(List.generate(70000, (i) => i));
        await dcA.sendBinary(payload);
        final gotB = await atB.timeout(const Duration(seconds: 30));
        expect(gotB[0].isBinary, isFalse);
        expect(gotB[0].text, 'hello from a');
        expect(gotB[1].isBinary, isTrue);
        expect(gotB[1].bytes, payload);

        final atA = dcA.onMessage.first;
        await dcB.send('hello from b');
        expect((await atA.timeout(const Duration(seconds: 30))).text,
            'hello from b');
      } finally {
        await a.close();
        await b.close();
      }
    });

    test('initializes from a spawned isolate (no MethodChannel)', () async {
      final result = await Isolate.run(() async {
        final pion = await _shared(lib);
        final pc = await pion.createPeerConnection();
        await pc.createDataChannel('worker');
        final sdp = await pc.createOffer();
        await pion.close();
        return jsonEncode({'handle': pc.handle, 'sdp': sdp});
      });
      final map = jsonDecode(result) as Map;
      expect(map['handle'] as String, hasLength(32));
      expect(map['sdp'] as String, contains('v=0'));
    });
  });
}
