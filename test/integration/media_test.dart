// Integration tests for transceivers and PionMediaEngine, run against BOTH
// transports. Remote-track delivery is covered by the Go tests
// (media_test.go), since sending media needs a Go peer.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pion_bridge/src/bridge.dart';
import 'package:pion_bridge/src/exception.dart';
import 'package:pion_bridge/src/types.dart';

import '../helpers/test_harness.dart';
import 'detached_data_channels_test.dart' show settings, sharedLibraryForTests;

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

  const codecs = PionMediaEngine(videoCodecs: ['AV1', 'VP9', 'VP8'], audioCodecs: ['opus']);

  for (final mode in ['websocket', 'shared']) {
    Future<PionBridge> open({PionMediaEngine? media}) => mode == 'websocket'
        ? PionBridge.connectExisting(
            PionServerEndpoint(port: harness.port, token: harness.token),
            settingsEngine: settings(detach: false),
            mediaEngine: media,
          )
        : PionBridge.initialize(
            mode: PionBridgeMode.shared,
            sharedLibraryPath: lib,
            settingsEngine: settings(detach: false),
            mediaEngine: media,
          );

    group('media ($mode)', () {
      test('transceivers become m-lines in order with the requested directions', () async {
        final b = await open(media: codecs);
        try {
          final pc = await b.createPeerConnection();
          expect(await pc.addTransceiver(MediaKind.video, TransceiverDirection.recvonly), 0);
          expect(await pc.addTransceiver(MediaKind.audio, TransceiverDirection.recvonly), 1);
          expect(await pc.addTransceiver(MediaKind.audio, TransceiverDirection.sendonly), 2);
          final sdp = await pc.createOffer();
          final sections = sdp.split('\r\nm=').skip(1).toList();
          expect(sections.length, 3);
          expect(sections[0], startsWith('video'));
          expect(sections[0], contains('a=recvonly'));
          expect(sections[1], startsWith('audio'));
          expect(sections[1], contains('a=recvonly'));
          expect(sections[2], contains('a=sendonly'));
          expect(sdp, contains('AV1/90000'));
          expect(sdp, isNot(contains('H264')));
        } finally {
          await b.close();
        }
      });

      test('a per-connection media engine overrides the session codecs', () async {
        final b = await open(media: codecs);
        try {
          final pc = await b.createPeerConnection(
              mediaEngine: const PionMediaEngine(videoCodecs: ['VP8']));
          await pc.addTransceiver(MediaKind.video, TransceiverDirection.recvonly);
          final sdp = await pc.createOffer();
          expect(sdp, contains('VP8/90000'));
          expect(sdp, isNot(contains('AV1')));
        } finally {
          await b.close();
        }
      });

      test('an unknown codec is rejected', () async {
        final b = await open();
        try {
          await expectLater(
            b.createPeerConnection(mediaEngine: const PionMediaEngine(videoCodecs: ['H264'])),
            throwsA(isA<PionException>().having((e) => e.code, 'code', 'INVALID_MEDIA_ENGINE')),
          );
        } finally {
          await b.close();
        }
      });
    });
  }
}
