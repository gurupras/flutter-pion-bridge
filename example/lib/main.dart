import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pion_bridge/pion_bridge.dart';
import 'remote_peer_tab.dart';

void main() {
  runApp(const PionBridgeExampleApp());
}

class PionBridgeExampleApp extends StatelessWidget {
  const PionBridgeExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pion Bridge Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const _HomeScreen(),
    );
  }
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  PionBridge? _bridge;
  String? _bridgeError;

  @override
  void initState() {
    super.initState();
    _initBridge();
  }

  Future<void> _initBridge() async {
    try {
      final bridge = await PionBridge.initialize(
        onDisconnected: () {
          if (mounted) {
            setState(() {
              _bridge = null;
              _bridgeError = 'Bridge disconnected';
            });
          }
        },
      );
      if (mounted) setState(() => _bridge = bridge);
    } catch (e) {
      if (mounted) setState(() => _bridgeError = 'Failed to initialize bridge: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bridgeError != null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(_bridgeError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: () {
              setState(() { _bridge = null; _bridgeError = null; });
              _initBridge();
            }, child: const Text('Retry')),
          ]),
        ),
      );
    }

    if (_bridge == null) {
      return const Scaffold(
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Initializing bridge…'),
        ])),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Pion Bridge Test'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.computer), text: 'Localhost'),
            Tab(icon: Icon(Icons.wifi), text: 'Remote Peer'),
          ]),
        ),
        body: TabBarView(children: [
          LocalhostTab(bridge: _bridge!),
          RemotePeerTab(bridge: _bridge!),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Localhost loopback throughput test
// ---------------------------------------------------------------------------

enum _TestState { idle, running, connected, completed, error }

class _TestResult {
  final int bytesTransferred;
  final Duration duration;
  final double mbps;

  _TestResult({
    required this.bytesTransferred,
    required this.duration,
    required this.mbps,
  });
}

class LocalhostTab extends StatefulWidget {
  final PionBridge bridge;
  const LocalhostTab({super.key, required this.bridge});

  @override
  State<LocalhostTab> createState() => _LocalhostTabState();
}

class _LocalhostTabState extends State<LocalhostTab>
    with AutomaticKeepAliveClientMixin {
  _TestState _state = _TestState.idle;
  String _status = 'Ready to test';
  _TestResult? _result;
  double _progress = 0;
  int _numChannels = 1;
  final _channelCtrl = TextEditingController(text: '1');

  PionPeerConnection? _serverPeer;
  PionPeerConnection? _clientPeer;
  List<PionDataChannel>? _dcs;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _channelCtrl.dispose();
    _cleanup();
    super.dispose();
  }

  Future<void> _runTest() async {
    setState(() {
      _state = _TestState.running;
      _status = '[1/6] Creating peer connections…';
      _result = null;
      _progress = 0;
    });

    try {
      _serverPeer = await widget.bridge.createPeerConnection();
      _clientPeer = await widget.bridge.createPeerConnection();

      _serverPeer!.onIceCandidate.listen((c) => _clientPeer!.addIceCandidate(c));
      _clientPeer!.onIceCandidate.listen((c) => _serverPeer!.addIceCandidate(c));

      setState(() => _status = '[2/6] Creating $_numChannels data channel(s)…');
      final serverDcs = <PionDataChannel>[];
      for (int i = 0; i < _numChannels; i++) {
        serverDcs.add(await _serverPeer!.createDataChannel('throughput-$i'));
      }
      _dcs = serverDcs;

      setState(() => _status = '[3/6] SDP offer/answer exchange…');
      final offer = await _serverPeer!.createOffer();
      await _serverPeer!.setLocalDescription(offer, 'offer');
      await _clientPeer!.setRemoteDescription(offer, 'offer');
      final answer = await _clientPeer!.createAnswer();
      await _clientPeer!.setLocalDescription(answer, 'answer');
      await _serverPeer!.setRemoteDescription(answer, 'answer');

      setState(() {
        _state = _TestState.connected;
        _status = '[4/6] Waiting for ${serverDcs.length} channel(s) to open…';
      });
      for (int i = 0; i < serverDcs.length; i++) {
        await serverDcs[i].onOpen.first;
        setState(() => _status = '[4/6] Channel $i opened (${i + 1}/${serverDcs.length})');
      }

      setState(() {
        _state = _TestState.running;
        _status = '[5/6] Sending data for 5s…';
        _progress = 0;
      });
      await _runSend(serverDcs);
    } catch (e) {
      if (mounted) setState(() { _state = _TestState.error; _status = 'Error: $e'; });
      _cleanup();
    }
  }

  Future<void> _runSend(List<PionDataChannel> dcs) async {
    const duration = Duration(seconds: 5);
    const chunkSize = 64 * 1024 - 8;
    final random = Random();
    int totalBytes = 0;
    int seq = 0;

    final done = Completer<void>();
    Timer(duration, () { if (!done.isCompleted) done.complete(); });
    Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (done.isCompleted) { t.cancel(); return; }
      if (mounted) setState(() => _progress = t.tick / (duration.inMilliseconds ~/ 100));
    });

    final sw = Stopwatch()..start();
    while (!done.isCompleted) {
      final payload = Uint8List(8 + chunkSize);
      _writeU64LE(payload, 0, seq);
      final data = List.generate(chunkSize, (_) => random.nextInt(256));
      payload.setRange(8, 8 + chunkSize, data);
      await dcs[seq % dcs.length].sendBinary(payload);
      totalBytes += chunkSize;
      seq++;
    }
    sw.stop();

    final result = _TestResult(
      bytesTransferred: totalBytes,
      duration: sw.elapsed,
      mbps: (totalBytes * 8) / sw.elapsed.inMilliseconds * 1000 / 1e6,
    );

    if (mounted) {
      setState(() {
        _state = _TestState.completed;
        _result = result;
        _status = 'Test complete';
        _progress = 1;
      });
    }
    _cleanup();
  }

  void _writeU64LE(Uint8List buf, int off, int v) {
    for (int i = 0; i < 8; i++) { buf[off + i] = v & 0xFF; v >>= 8; }
  }

  void _cleanup() {
    try {
      _dcs?.forEach((dc) => dc.close());
      _serverPeer?.close();
      _clientPeer?.close();
    } catch (_) {}
    _dcs = null;
    _serverPeer = null;
    _clientPeer = null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final canRun = _state == _TestState.idle ||
        _state == _TestState.completed ||
        _state == _TestState.error;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Configuration', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _channelCtrl,
                      enabled: canRun,
                      keyboardType: TextInputType.number,
                      onChanged: (v) => _numChannels = (int.tryParse(v) ?? 1).clamp(1, 16),
                      decoration: const InputDecoration(
                        labelText: 'Data Channels (1–16)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Status', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _stateRow(),
                const SizedBox(height: 4),
                Text(_status),
              ]),
            ),
          ),
          if (_state == _TestState.running || _state == _TestState.connected) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progress > 0 ? _progress.clamp(0.0, 1.0) : null,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Results', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _row('Data Channels', '$_numChannels'),
                  _row('Transferred', '${(_result!.bytesTransferred / 1e6).toStringAsFixed(2)} MB'),
                  _row('Duration', '${_result!.duration.inMilliseconds} ms'),
                  _row('Throughput', '${_result!.mbps.toStringAsFixed(2)} Mbps'),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: canRun ? _runTest : null,
            child: Text(_state == _TestState.completed ? 'Run Again' : 'Start Test'),
          ),
        ],
      ),
    );
  }

  Widget _stateRow() {
    final (color, icon) = switch (_state) {
      _TestState.idle      => (Colors.grey, Icons.hourglass_empty),
      _TestState.running   => (Colors.blue, Icons.play_arrow),
      _TestState.connected => (Colors.green, Icons.check_circle),
      _TestState.completed => (Colors.teal, Icons.done_all),
      _TestState.error     => (Colors.red, Icons.error),
    };
    return Row(children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 8),
      Text(_state.name.toUpperCase(),
          style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    ]);
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label),
      Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
    ]),
  );
}
