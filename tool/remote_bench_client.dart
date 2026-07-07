// Local side of the cross-machine WebRTC benchmark (pure Dart, no Flutter).
//
// Spawns a LOCAL pionbridge Go server binary (passed via --bin so the same
// client can drive a baseline or a patched build), then connects through the
// full Dart bridge stack to a remote benchpeer (go/cmd/benchpeer) over a real
// network path, and measures connect time, bidirectional throughput, and
// DataChannel RTT.
//
//   dart run tool/remote_bench_client.dart \
//     --signaling ws://192.168.2.66:8765 --bin /path/to/pionbridge [--size-mb 8]
//
// IMPORTANT: this file must stay source-compatible with BOTH the baseline
// (v4.0.0) and current lib/ APIs — it deliberately avoids `timeout:`
// parameters, `PionSettingsEngine.interfaceWhitelist`, and event-buffering
// assumptions (all streams are subscribed before signaling starts).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pion_bridge/src/event_dispatcher.dart';
import 'package:pion_bridge/src/peer_connection.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';

Future<void> main(List<String> args) async {
  var signalingUrl = 'ws://192.168.2.66:8765';
  String? binPath;
  var sizeMb = 8;
  for (var i = 0; i < args.length - 1; i++) {
    switch (args[i]) {
      case '--signaling':
        signalingUrl = args[i + 1];
      case '--bin':
        binPath = args[i + 1];
      case '--size-mb':
        sizeMb = int.parse(args[i + 1]);
    }
  }
  if (binPath == null) {
    stderr.writeln('usage: --bin <pionbridge binary> [--signaling ws://...]');
    exit(2);
  }
  final totalBytes = sizeMb * 1024 * 1024;

  // --- Local Go bridge server ---
  final goProc = await Process.start(binPath, []);
  goProc.stderr.transform(utf8.decoder).listen((_) {});
  final startup = jsonDecode(await goProc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first) as Map<String, dynamic>;

  final dispatcher = EventDispatcher();
  final conn = WebSocketConnection(onMessage: dispatcher.broadcast);
  await conn.connect('ws://127.0.0.1:${startup['port']}/',
      token: startup['token'] as String);
  await conn.request('init', null, {}); // defaults: real interfaces

  // --- Signaling ---
  final sig = await WebSocket.connect(signalingUrl)
      .timeout(const Duration(seconds: 15));
  final fromPeer = StreamController<Map<String, dynamic>>.broadcast();
  sig.listen(
      (raw) => fromPeer.add(jsonDecode(raw as String) as Map<String, dynamic>));
  void send(Map<String, dynamic> m) => sig.add(jsonEncode(m));
  Future<Map<String, dynamic>> await_(String type,
          [Duration timeout = const Duration(seconds: 60)]) =>
      fromPeer.stream.firstWhere((m) => m['t'] == type).timeout(timeout);

  send({'t': 'hello'});
  await await_('hello-ack', const Duration(seconds: 15));

  // --- Peer (offerer) ---
  final pcResp = await conn.request('pc:create', null, {
    'ice_servers': [],
    'bundle_policy': 'balanced',
    'rtcp_mux_policy': 'require',
  });
  final pc = PionPeerConnection(pcResp['handle'] as String, conn, dispatcher);
  pc.onIceCandidate.listen((c) => send({
        't': 'ice',
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMlineIndex': c.sdpMlineIndex,
      }));
  fromPeer.stream.where((m) => m['t'] == 'ice').listen((m) {
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
  var downTarget = 0;
  Completer<void>? downDone;
  final pongs = StreamController<String>.broadcast();
  dc.onMessage.listen((m) {
    if (m.isBinary) {
      downReceived += m.bytes.length;
      if (downTarget > 0 && downReceived >= downTarget) {
        downTarget = 0;
        downDone?.complete();
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
  await opened.future.timeout(const Duration(seconds: 60), onTimeout: () {
    stderr.writeln('FATAL: DataChannel did not open within 60s');
    exit(1);
  });
  final connectMs = connectWatch.elapsedMilliseconds;

  // --- Upload ---
  const chunkSize = 64 * 1024;
  final chunk = Uint8List(chunkSize);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = i & 0xFF;
  }
  send({'t': 'up-start', 'bytes': totalBytes});
  var sent = 0;
  while (sent < totalBytes) {
    await dc.sendBinary(chunk);
    sent += chunkSize;
  }
  final upMs = (await await_('up-done', const Duration(minutes: 3)))['ms'] as int;

  // --- Download ---
  downReceived = 0;
  downTarget = totalBytes;
  downDone = Completer<void>();
  final downWatch = Stopwatch()..start();
  send({'t': 'down-start', 'bytes': totalBytes});
  await downDone.future.timeout(const Duration(minutes: 3), onTimeout: () {
    stderr.writeln('FATAL: download incomplete ($downReceived/$totalBytes)');
    exit(1);
  });
  final downMs = downWatch.elapsedMilliseconds;

  // --- RTT (20 sequential DC ping/pong round trips) ---
  final rtts = <int>[];
  for (var i = 0; i < 20; i++) {
    final watch = Stopwatch()..start();
    final reply = pongs.stream.firstWhere((p) => p == 'PONG:$i');
    await dc.send('PING:$i');
    await reply.timeout(const Duration(seconds: 10));
    rtts.add(watch.elapsedMicroseconds);
  }
  rtts.sort();

  double mbps(int bytes, int ms) => ms == 0 ? 0 : bytes * 8 / ms / 1000;
  final results = {
    'connect_ms': connectMs,
    'up_mbps': double.parse(mbps(totalBytes, upMs).toStringAsFixed(2)),
    'down_mbps': double.parse(mbps(totalBytes, downMs).toStringAsFixed(2)),
    'median_rtt_us': rtts[rtts.length ~/ 2],
    'min_rtt_us': rtts.first,
    'size_mb': sizeMb,
  };
  stdout.writeln('BENCH-RESULTS ${jsonEncode(results)}');
  send({'t': 'bye', 'results': results});
  await Future<void>.delayed(const Duration(milliseconds: 300));

  await sig.close();
  await conn.close();
  goProc.kill();
  exit(0);
}
