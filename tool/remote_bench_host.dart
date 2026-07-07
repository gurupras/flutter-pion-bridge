// Host side of the cross-device WebRTC benchmark.
//
// Runs on the development machine with plain `dart run` (no Flutter): spawns
// the Go pionbridge server as a child process, serves a WebSocket signaling
// endpoint on 0.0.0.0:<port>, answers one peer (typically the example app's
// integration test running on an Android emulator, which reaches this host
// at 10.0.2.2), and acts as the sink/source for the throughput phases plus a
// PING/PONG echo responder for RTT measurement.
//
// Usage:
//   dart run tool/remote_bench_host.dart [--port 8765] [--size-mb 8]
//
// Protocol (JSON text frames over the signaling WebSocket):
//   client → host : {"t":"hello"}
//   client → host : {"t":"offer","sdp":...}
//   host  → client: {"t":"answer","sdp":...}
//   both         : {"t":"ice","candidate":...,"sdpMid":...,"sdpMlineIndex":...}
//   client → host : {"t":"up-start","bytes":N}    // client sends N bytes on the DC
//   host  → client: {"t":"up-done","ms":elapsed}  // host received all N bytes
//   client → host : {"t":"down-start","bytes":N}  // host sends N bytes on the DC
//   client → host : {"t":"bye","results":{...}}   // host prints results, exits
//
// The DataChannel itself carries binary payload chunks and text "PING:i"
// frames, which the host echoes back as "PONG:i".

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pion_bridge/src/event_dispatcher.dart';
import 'package:pion_bridge/src/peer_connection.dart';
import 'package:pion_bridge/src/data_channel.dart';
import 'package:pion_bridge/src/types.dart';
import 'package:pion_bridge/src/websocket_connection.dart';

Future<void> main(List<String> args) async {
  var sigPort = 8765;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') sigPort = int.parse(args[i + 1]);
  }

  // --- Spawn the Go server (same approach as test/helpers/test_harness) ---
  final repoRoot = File(Platform.script.toFilePath()).parent.parent.path;
  final goDir = '$repoRoot/go';
  final binPath = '$goDir/pionbridge_bench_bin';
  final build = await Process.run('go', ['build', '-o', binPath, '.'],
      workingDirectory: goDir);
  if (build.exitCode != 0) {
    stderr.writeln('go build failed:\n${build.stderr}');
    exit(1);
  }
  final goProc = await Process.start(binPath, []);
  goProc.stderr.transform(utf8.decoder).listen((_) {}); // drain
  final startupLine = await goProc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  final startup = jsonDecode(startupLine) as Map<String, dynamic>;

  final dispatcher = EventDispatcher();
  final conn = WebSocketConnection(onMessage: dispatcher.broadcast);
  await conn.connect('ws://127.0.0.1:${startup['port']}/',
      token: startup['token'] as String);
  // Default init: gather on REAL interfaces — the emulator must be able to
  // reach this host's LAN address, so no loopback whitelist here.
  await conn.request('init', null, {});

  // --- Signaling server ---
  final sigServer = await HttpServer.bind(InternetAddress.anyIPv4, sigPort);
  stdout.writeln('BENCH-HOST-READY port=$sigPort');

  final req = await sigServer.first;
  final sig = await WebSocketTransformer.upgrade(req);
  void send(Map<String, dynamic> m) => sig.add(jsonEncode(m));

  // --- Peer setup (answerer) ---
  final pcResp = await conn.request('pc:create', null, {
    'ice_servers': [],
    'bundle_policy': 'balanced',
    'rtcp_mux_policy': 'require',
  });
  final pc =
      PionPeerConnection(pcResp['handle'] as String, conn, dispatcher);

  pc.onIceCandidate.listen((c) => send({
        't': 'ice',
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMlineIndex': c.sdpMlineIndex,
      }));

  var upExpected = 0;
  var upReceived = 0;
  Stopwatch? upWatch;

  final dcReady = Completer<PionDataChannel>();
  pc.onDataChannel.listen((channel) {
    channel.onMessage.listen((DataChannelMessage m) {
      if (m.isBinary) {
        upReceived += m.bytes.length;
        if (upExpected > 0 && upReceived >= upExpected) {
          final ms = upWatch?.elapsedMilliseconds ?? 0;
          upExpected = 0;
          send({'t': 'up-done', 'ms': ms, 'bytes': upReceived});
        }
      } else {
        final text = m.text;
        if (text.startsWith('PING:')) {
          channel.send('PONG:${text.substring(5)}');
        }
      }
    });
    if (!dcReady.isCompleted) dcReady.complete(channel);
  });

  final done = Completer<void>();

  sig.listen((raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['t'] as String) {
      case 'hello':
        send({'t': 'hello-ack'});
      case 'offer':
        await pc.setRemoteDescription(m['sdp'] as String, 'offer');
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer, 'answer');
        send({'t': 'answer', 'sdp': answer});
      case 'ice':
        await pc
            .addIceCandidate(IceCandidate(
              candidate: m['candidate'] as String,
              sdpMid: (m['sdpMid'] as String?) ?? '',
              sdpMlineIndex: (m['sdpMlineIndex'] as num?)?.toInt() ?? 0,
            ))
            .catchError((_) {});
      case 'up-start':
        upExpected = m['bytes'] as int;
        upReceived = 0;
        upWatch = Stopwatch()..start();
      case 'down-start':
        final total = m['bytes'] as int;
        const chunkSize = 64 * 1024;
        final chunk = Uint8List(chunkSize);
        for (var i = 0; i < chunk.length; i++) {
          chunk[i] = i & 0xFF;
        }
        final channel = await dcReady.future;
        var sent = 0;
        final watch = Stopwatch()..start();
        while (sent < total) {
          final n = (total - sent).clamp(0, chunkSize);
          await channel.sendBinary(
            n == chunkSize ? chunk : Uint8List.sublistView(chunk, 0, n),
            timeout: const Duration(seconds: 120),
          );
          sent += n;
        }
        send({'t': 'down-sent', 'ms': watch.elapsedMilliseconds});
      case 'bye':
        stdout.writeln('BENCH-RESULTS ${jsonEncode(m['results'])}');
        if (!done.isCompleted) done.complete();
    }
  }, onDone: () {
    if (!done.isCompleted) done.complete();
  });

  await done.future.timeout(const Duration(minutes: 10), onTimeout: () {
    stderr.writeln('bench host timed out waiting for client');
  });

  await conn.close();
  goProc.kill();
  await sigServer.close(force: true);
  exit(0);
}
