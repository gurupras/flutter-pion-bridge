// Cross-device WebRTC benchmark — runs ON a device/emulator and talks to a
// peer on the development host, so the media path crosses a real network
// boundary (emulator NAT → host NIC) instead of loopback.
//
// This is the one scenario the loopback test suites cannot cover, and the
// one where the vendored pion/sctp RTO patch (rtoInitial 200ms / rtoMin
// 100ms) carries real-network risk: once RTT + jitter approaches the 100ms
// floor, spurious retransmissions collapse the congestion window.
//
// Run:
//   1. On the host:      dart run tool/remote_bench_host.dart --port 8765
//   2. On the emulator:  cd example && flutter test --device-id <emulator> \
//        integration_test/remote_benchmark_test.dart \
//        [--dart-define=SIGNALING=ws://10.0.2.2:8765] \
//        [--dart-define=SIZE_MB=8]
//
// 10.0.2.2 is the Android emulator's alias for the host. For a physical
// device, pass the host's LAN address instead.
//
// To probe RTO behaviour under latency, boot the emulator with e.g.
// `-netdelay 40:80` (min:max ms one-way) and compare throughput/RTT.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pion_bridge/pion_bridge.dart';

const _signalingUrl =
    String.fromEnvironment('SIGNALING', defaultValue: 'ws://10.0.2.2:8765');
const _sizeMb = int.fromEnvironment('SIZE_MB', defaultValue: 8);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('cross-device throughput + RTT benchmark (non-loopback path)',
      () async {
    final totalBytes = _sizeMb * 1024 * 1024;

    final bridge = await PionBridge.initialize();
    final sig = await WebSocket.connect(_signalingUrl)
        .timeout(const Duration(seconds: 15));

    final fromHost = StreamController<Map<String, dynamic>>.broadcast();
    sig.listen((raw) =>
        fromHost.add(jsonDecode(raw as String) as Map<String, dynamic>));
    void send(Map<String, dynamic> m) => sig.add(jsonEncode(m));

    Future<Map<String, dynamic>> await_(String type,
        [Duration timeout = const Duration(seconds: 60)]) =>
        fromHost.stream.firstWhere((m) => m['t'] == type).timeout(timeout);

    send({'t': 'hello'});
    await await_('hello-ack', const Duration(seconds: 15));

    // --- Peer setup (offerer). Default settings: real interfaces. ---
    final pc = await bridge.createPeerConnection();
    pc.onIceCandidate.listen((c) => send({
          't': 'ice',
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMlineIndex': c.sdpMlineIndex,
        }));
    final iceSub = fromHost.stream.where((m) => m['t'] == 'ice').listen((m) {
      pc
          .addIceCandidate(IceCandidate(
            candidate: m['candidate'] as String,
            sdpMid: (m['sdpMid'] as String?) ?? '',
            sdpMlineIndex: (m['sdpMlineIndex'] as num?)?.toInt() ?? 0,
          ))
          .catchError((_) {});
    });

    final dc = await pc.createDataChannel('bench');
    final opened = Completer<void>();
    dc.onOpen.listen((_) {
      if (!opened.isCompleted) opened.complete();
    });

    var downReceived = 0;
    Completer<void>? downDone;
    var downTarget = 0;
    final pongs = StreamController<String>.broadcast();
    dc.onMessage.listen((m) {
      if (m.isBinary) {
        downReceived += m.bytes.length;
        if (downTarget > 0 && downReceived >= downTarget) {
          downDone?.complete();
          downTarget = 0;
        }
      } else if (m.text.startsWith('PONG:')) {
        pongs.add(m.text);
      }
    });

    final connectWatch = Stopwatch()..start();
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer, 'offer');
    send({'t': 'offer', 'sdp': offer});
    final answer = await await_('answer');
    await pc.setRemoteDescription(answer['sdp'] as String, 'answer');

    await opened.future.timeout(const Duration(seconds: 60),
        onTimeout: () => fail(
            'DataChannel did not open across the device boundary within 60s'));
    final connectMs = connectWatch.elapsedMilliseconds;

    // --- Phase 1: upload (device → host) ---
    const chunkSize = 64 * 1024;
    final chunk = Uint8List(chunkSize);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = i & 0xFF;
    }
    send({'t': 'up-start', 'bytes': totalBytes});
    var sent = 0;
    final upWatch = Stopwatch()..start();
    while (sent < totalBytes) {
      await dc.sendBinary(chunk, timeout: const Duration(seconds: 120));
      sent += chunkSize;
    }
    final upDone = await await_('up-done', const Duration(minutes: 3));
    final upMs = upDone['ms'] as int;

    // --- Phase 2: download (host → device) ---
    downReceived = 0;
    downTarget = totalBytes;
    downDone = Completer<void>();
    final downWatch = Stopwatch()..start();
    send({'t': 'down-start', 'bytes': totalBytes});
    await downDone!.future.timeout(const Duration(minutes: 3),
        onTimeout: () => fail(
            'download incomplete: $downReceived of $totalBytes bytes'));
    final downMs = downWatch.elapsedMilliseconds;

    // --- Phase 3: RTT via DC ping/pong (20 sequential round trips) ---
    final rtts = <int>[];
    for (var i = 0; i < 20; i++) {
      final watch = Stopwatch()..start();
      final reply = pongs.stream.firstWhere((p) => p == 'PONG:$i');
      await dc.send('PING:$i');
      await reply.timeout(const Duration(seconds: 10));
      rtts.add(watch.elapsedMicroseconds);
    }
    rtts.sort();
    final medianRttUs = rtts[rtts.length ~/ 2];

    double mbps(int bytes, int ms) => ms == 0 ? 0 : bytes * 8 / ms / 1000;
    final results = {
      'connect_ms': connectMs,
      'up_mbps': double.parse(mbps(totalBytes, upMs).toStringAsFixed(2)),
      'down_mbps': double.parse(mbps(totalBytes, downMs).toStringAsFixed(2)),
      'median_rtt_us': medianRttUs,
      'size_mb': _sizeMb,
    };
    // ignore: avoid_print
    print('BENCH-RESULTS ${jsonEncode(results)}');
    send({'t': 'bye', 'results': results});

    await iceSub.cancel();
    await sig.close();
    await bridge.close();

    // Sanity floors — this asserts the path WORKS off-loopback; the numbers
    // themselves are reported for human judgement.
    expect(connectMs, lessThan(60000));
    expect(mbps(totalBytes, upMs), greaterThan(0.5),
        reason: 'upload throughput collapsed');
    expect(mbps(totalBytes, downMs), greaterThan(0.5),
        reason: 'download throughput collapsed');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
