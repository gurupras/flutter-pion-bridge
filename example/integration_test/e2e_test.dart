// Cheap end-to-end smoke test of every bridge mode a platform ships, run inside
// the example app so it exercises what apps actually get: the bundled (or
// release-downloaded) binaries, the native plugin and the platform channel.
//
//   cd example && flutter test -d <device> integration_test/e2e_test.dart
//
// Modes per platform:
//   websocket  everywhere — a sidecar process on Linux/macOS/Windows, the
//              in-process gomobile server on Android/iOS
//   shared     Linux, macOS, Windows — the library loaded with dart:ffi
//
// tooling/ci/e2e/ runs it on every platform; see RELEASING.md.

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pion_bridge/pion_bridge.dart';

final bool _desktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;

// Loopback-only ICE keeps setup instant and deterministic on hosts with many
// interfaces. The loopback interface is lo0 on Apple platforms and lo on
// Linux/Android; Windows has no stable name for it, so there the loopback
// candidate is included without a whitelist.
final _loopback = PionSettingsEngine(
  interfaceWhitelist: Platform.isWindows
      ? null
      : [Platform.isMacOS || Platform.isIOS ? 'lo0' : 'lo'],
  includeLoopbackCandidate: true,
);

const _timeout = Duration(seconds: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bridges = <PionBridge>[];

  tearDown(() async {
    for (final bridge in bridges) {
      try {
        await bridge.close();
      } catch (_) {}
    }
    bridges.clear();
  });

  Future<PionBridge> open(PionBridgeMode mode) async {
    final bridge = await PionBridge.initialize(mode: mode, settingsEngine: _loopback);
    bridges.add(bridge);
    expect(bridge.mode, mode);
    expect(bridge.isConnected, isTrue);
    return bridge;
  }

  final modes = [PionBridgeMode.websocket, if (_desktop) PionBridgeMode.shared];
  for (final mode in modes) {
    test('${mode.name}: two peers exchange text and binary over a DataChannel',
        () async {
      final bridge = await open(mode);
      await _exchange(bridge, bridge);
    });
  }

  if (_desktop) {
    // Peers on a sidecar bridge and an in-process bridge in the same app: both
    // transports carry the same protocol, so they must interoperate.
    test('websocket and shared bridges interoperate', () async {
      final websocket = await open(PionBridgeMode.websocket);
      final shared = await open(PionBridgeMode.shared);
      await _exchange(websocket, shared);
    });
  }
}

/// Connects a peer on [a] to a peer on [b] and sends text and binary both ways.
Future<void> _exchange(PionBridge a, PionBridge b) async {
  final offerer = await a.createPeerConnection();
  final answerer = await b.createPeerConnection();

  // Trickle ICE, as TestHarness.createConnectedPair does; candidates that race
  // ahead of the remote description are dropped, and the rest still connect.
  offerer.onIceCandidate.listen((c) => answerer.addIceCandidate(c).catchError((_) {}));
  answerer.onIceCandidate.listen((c) => offerer.addIceCandidate(c).catchError((_) {}));

  final remoteChannel = answerer.onDataChannel.first;
  final local = await offerer.createDataChannel('e2e');
  final localOpen = local.onOpen.first;

  final offer = await offerer.createOffer();
  await offerer.setLocalDescription(offer, 'offer');
  await answerer.setRemoteDescription(offer, 'offer');
  final answer = await answerer.createAnswer();
  await answerer.setLocalDescription(answer, 'answer');
  await offerer.setRemoteDescription(answer, 'answer');

  await localOpen.timeout(_timeout, onTimeout: () => fail('DataChannel never opened'));
  final remote = await remoteChannel.timeout(_timeout,
      onTimeout: () => fail('answerer never received the DataChannel'));

  // 64 KiB spans many SCTP chunks without making the test slow.
  final payload = Uint8List.fromList(List.generate(64 * 1024, (i) => i % 251));

  final atRemote = remote.onMessage.take(2).toList();
  await local.send('ping');
  await local.sendBinary(payload);
  final received = await atRemote.timeout(_timeout,
      onTimeout: () => fail('messages never reached the answerer'));
  expect(received[0].isBinary, isFalse);
  expect(received[0].text, 'ping');
  expect(received[1].isBinary, isTrue);
  expect(received[1].bytes, payload);

  final atLocal = local.onMessage.take(2).toList();
  final reversed = Uint8List.fromList(payload.reversed.toList());
  await remote.send('pong');
  await remote.sendBinary(reversed);
  final replies = await atLocal.timeout(_timeout,
      onTimeout: () => fail('replies never reached the offerer'));
  expect(replies[0].text, 'pong');
  expect(replies[1].bytes, reversed);

  await offerer.close();
  await answerer.close();
}
