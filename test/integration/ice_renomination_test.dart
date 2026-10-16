// Integration tests for PionSettingsEngine.iceRenomination, run against BOTH
// transports: the keys must cross the wire and reach pion, and renomination
// must stay off unless asked for.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/bridge.dart';
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/types.dart';

import '../helpers/test_harness.dart';
import 'detached_data_channels_test.dart' show sharedLibraryForTests;

/// Loopback ICE plus renomination; a per-connection settings engine replaces
/// the session's, so it has to carry the loopback settings too.
PionSettingsEngine settings({bool? renomination, int? intervalMs}) =>
    PionSettingsEngine(
      interfaceWhitelist:
          Platform.isWindows ? null : [Platform.isMacOS ? 'lo0' : 'lo'],
      includeLoopbackCandidate: true,
      iceRenomination: renomination,
      iceRenominationIntervalMs: intervalMs,
    );

void main() {
  late TestHarness harness;
  late String lib;

  setUpAll(() async {
    await TestHarness.ensureBinary();
    lib = await sharedLibraryForTests();
  });
  tearDownAll(() => TestHarness.cleanupBinary());
  setUp(() async {
    harness = TestHarness();
    await harness.start();
  });
  tearDown(() async => harness.stop());

  for (final mode in ['websocket', 'shared']) {
    Future<PionBridge> open() => mode == 'websocket'
        ? PionBridge.connectExisting(
            PionServerEndpoint(port: harness.port, token: harness.token),
            settingsEngine: settings(),
          )
        : PionBridge.initialize(
            mode: PionBridgeMode.shared,
            sharedLibraryPath: lib,
            settingsEngine: settings(),
          );

    // pion advertises a=ice-options:renomination exactly when renomination is
    // enabled on the connection's SettingEngine.
    Future<String> offerFor(PionBridge b, PionSettingsEngine? se) async {
      final pc = await b.createPeerConnection(settingsEngine: se);
      await pc.createDataChannel('probe');
      return pc.createOffer();
    }

    group('ice renomination ($mode)', () {
      test('is off by default and with false, on with true', () async {
        final b = await open();
        try {
          expect(await offerFor(b, null), isNot(contains('renomination')));
          expect(
              await offerFor(b, settings()), isNot(contains('renomination')));
          expect(await offerFor(b, settings(renomination: false)),
              isNot(contains('renomination')));
          expect(await offerFor(b, settings(intervalMs: 2000)),
              isNot(contains('renomination')));
          expect(await offerFor(b, settings(renomination: true)),
              contains('renomination'));
          expect(
              await offerFor(b, settings(renomination: true, intervalMs: 2000)),
              contains('renomination'));
        } finally {
          await b.close();
        }
      });

      test('a zero interval is rejected', () async {
        final b = await open();
        try {
          await expectLater(
            b.createPeerConnection(
                settingsEngine: settings(renomination: true, intervalMs: 0)),
            throwsA(isA<PionException>().having((e) => e.message, 'message',
                contains('ice_renomination_interval_ms'))),
          );
        } finally {
          await b.close();
        }
      });

      test('peers connect and exchange data with renomination on', () async {
        final a = await open(), b = await open();
        try {
          final on = settings(renomination: true, intervalMs: 500);
          final offerer = await a.createPeerConnection(settingsEngine: on);
          final answerer = await b.createPeerConnection(settingsEngine: on);
          offerer.onIceCandidate
              .listen((c) => answerer.addIceCandidate(c).catchError((_) {}));
          answerer.onIceCandidate
              .listen((c) => offerer.addIceCandidate(c).catchError((_) {}));
          final remote = Completer<PionDataChannel>();
          answerer.onDataChannel.listen(remote.complete);
          final local = await offerer.createDataChannel('renom');
          final opened = local.onOpen.first;

          final offer = await offerer.createOffer();
          expect(offer, contains('renomination'));
          await offerer.setLocalDescription(offer, 'offer');
          await answerer.setRemoteDescription(offer, 'offer');
          final answer = await answerer.createAnswer();
          expect(answer, contains('renomination'));
          await answerer.setLocalDescription(answer, 'answer');
          await offerer.setRemoteDescription(answer, 'answer');
          await opened.timeout(const Duration(seconds: 30));
          final dc = await remote.future.timeout(const Duration(seconds: 30));

          // Past a few renomination intervals, the channel still carries data.
          await Future<void>.delayed(const Duration(seconds: 2));
          final got = dc.onMessage.first;
          await local.send('still connected');
          expect((await got.timeout(const Duration(seconds: 10))).text,
              'still connected');
        } finally {
          await a.close();
          await b.close();
        }
      });
    });
  }
}
