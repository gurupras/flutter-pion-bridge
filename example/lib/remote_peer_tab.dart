import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pion_bridge/pion_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Native send-buffer thresholds (matches flutter-maxp2p-pion convention).
const int _kHighWater = 512 * 1024; // 512 KB — stop sending above this
const int _kLowWater  = 128 * 1024; // 128 KB — resume when pion drops below this

enum _Phase { idle, connecting, testing, done, error }

class RemotePeerTab extends StatefulWidget {
  final PionBridge bridge;
  const RemotePeerTab({super.key, required this.bridge});

  @override
  State<RemotePeerTab> createState() => _RemotePeerTabState();
}

class _RemotePeerTabState extends State<RemotePeerTab>
    with AutomaticKeepAliveClientMixin {
  _Phase _phase = _Phase.idle;
  String _status = 'Configure settings and tap Connect';
  bool _isOfferer = true;
  int _durationSeconds = 10;

  final _sigUrlCtrl  = TextEditingController();
  final _localIdCtrl = TextEditingController();
  final _remoteIdCtrl = TextEditingController();

  int _bytesSent = 0;
  int _bytesReceived = 0;
  double _rateMbps = 0;
  double _progress = 0;
  int _elapsedMs = 0;

  PionPeerConnection? _pc;
  PionDataChannel? _dc;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _sigUrlCtrl.dispose();
    _localIdCtrl.dispose();
    _remoteIdCtrl.dispose();
    _cleanup();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sigUrlCtrl.text  = p.getString('bridge_sig_url')   ?? 'ws://192.168.1.1:8080';
      _localIdCtrl.text = p.getString('bridge_local_id')  ?? 'flutter-bridge';
      _remoteIdCtrl.text = p.getString('bridge_remote_id') ?? 'peer';
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    p.setString('bridge_sig_url',   _sigUrlCtrl.text.trim());
    p.setString('bridge_local_id',  _localIdCtrl.text.trim());
    p.setString('bridge_remote_id', _remoteIdCtrl.text.trim());
  }

  void _cleanup() {
    _wsSub?.cancel();
    _ws?.sink.close();
    try { _dc?.close(); } catch (_) {}
    try { _pc?.close(); } catch (_) {}
    _wsSub = null;
    _ws = null;
    _dc = null;
    _pc = null;
  }

  void _sendSig(Map<String, dynamic> payload) {
    _ws?.sink.add(jsonEncode({
      'to': _remoteIdCtrl.text.trim(),
      'payload': payload,
    }));
  }

  Future<void> _connect() async {
    await _savePrefs();
    setState(() {
      _phase = _Phase.connecting;
      _status = 'Connecting to signaling server…';
      _bytesSent = 0;
      _bytesReceived = 0;
      _rateMbps = 0;
      _progress = 0;
      _elapsedMs = 0;
    });

    try {
      final uri = Uri.parse(
          '${_sigUrlCtrl.text.trim()}/ws?id=${Uri.encodeComponent(_localIdCtrl.text.trim())}');
      _ws = WebSocketChannel.connect(uri);
      await _ws!.ready;

      _pc = await widget.bridge.createPeerConnection();

      if (_isOfferer) {
        await _runOfferer();
      } else {
        await _runAnswerer();
      }
    } catch (e, st) {
      debugPrint('[Remote] $e\n$st');
      if (mounted) setState(() { _phase = _Phase.error; _status = 'Error: $e'; });
      _cleanup();
    }
  }

  // --------------------------------------------------------------------------
  // Offerer path
  // --------------------------------------------------------------------------

  Future<void> _runOfferer() async {
    setState(() => _status = 'Creating data channel…');
    _dc = await _pc!.createDataChannel('data');

    _pc!.onIceCandidate.listen((c) => _sendSig({
      'type': 'ice_candidate',
      'candidate': c.candidate,
      'sdpMid': c.sdpMid,
      'sdpMlineIndex': c.sdpMlineIndex,
    }));

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer, 'offer');
    _sendSig({'type': 'offer', 'sdp': offer});
    setState(() => _status = 'Offer sent. Waiting for answer from "${_remoteIdCtrl.text.trim()}"…');

    final answerCompleter = Completer<String>();
    _wsSub = _ws!.stream.listen((raw) {
      final outer = jsonDecode(raw as String) as Map<String, dynamic>;
      final payload = (outer['payload'] as Map?)?.cast<String, dynamic>();
      if (payload == null) return;
      switch (payload['type'] as String?) {
        case 'answer':
          if (!answerCompleter.isCompleted) answerCompleter.complete(payload['sdp'] as String);
        case 'ice_candidate':
          _pc!.addIceCandidate(IceCandidate(
            candidate: payload['candidate'] as String? ?? '',
            sdpMid: payload['sdpMid'] as String? ?? '',
            sdpMlineIndex: (payload['sdpMlineIndex'] as num?)?.toInt() ?? 0,
          ));
      }
    });

    await _pc!.setRemoteDescription(await answerCompleter.future, 'answer');
    setState(() => _status = 'Answer received. Waiting for channel to open…');

    await _dc!.onOpen.first;
    setState(() { _phase = _Phase.testing; _status = 'Sending for ${_durationSeconds}s…'; });
    await _runSenderTest();
  }

  // --------------------------------------------------------------------------
  // Answerer path
  // --------------------------------------------------------------------------

  Future<void> _runAnswerer() async {
    setState(() => _status = 'Registered. Waiting for offer from "${_remoteIdCtrl.text.trim()}"…');

    final pendingIce = <IceCandidate>[];
    bool remoteSet = false;
    final offerCompleter = Completer<String>();
    final dcCompleter    = Completer<PionDataChannel>();

    _pc!.onIceCandidate.listen((c) => _sendSig({
      'type': 'ice_candidate',
      'candidate': c.candidate,
      'sdpMid': c.sdpMid,
      'sdpMlineIndex': c.sdpMlineIndex,
    }));

    _pc!.onDataChannel.listen((dc) {
      if (!dcCompleter.isCompleted) dcCompleter.complete(dc);
    });

    _wsSub = _ws!.stream.listen((raw) {
      final outer = jsonDecode(raw as String) as Map<String, dynamic>;
      final payload = (outer['payload'] as Map?)?.cast<String, dynamic>();
      if (payload == null) return;
      switch (payload['type'] as String?) {
        case 'offer':
          if (!offerCompleter.isCompleted) offerCompleter.complete(payload['sdp'] as String);
        case 'ice_candidate':
          final c = IceCandidate(
            candidate: payload['candidate'] as String? ?? '',
            sdpMid: payload['sdpMid'] as String? ?? '',
            sdpMlineIndex: (payload['sdpMlineIndex'] as num?)?.toInt() ?? 0,
          );
          if (remoteSet) { _pc!.addIceCandidate(c); } else { pendingIce.add(c); }
      }
    });

    final offerSdp = await offerCompleter.future;
    setState(() => _status = 'Offer received. Creating answer…');

    await _pc!.setRemoteDescription(offerSdp, 'offer');
    remoteSet = true;
    for (final c in pendingIce) { _pc!.addIceCandidate(c); }

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer, 'answer');
    _sendSig({'type': 'answer', 'sdp': answer});
    setState(() => _status = 'Answer sent. Waiting for channel to open…');

    _dc = await dcCompleter.future;
    await _dc!.onOpen.first;
    setState(() { _phase = _Phase.testing; _status = 'Receiving…'; });
    await _runReceiverTest();
  }

  // --------------------------------------------------------------------------
  // Sender test: flow-controlled via onBufferedAmountLow
  // --------------------------------------------------------------------------

  Future<void> _runSenderTest() async {
    const chunkSize = 64 * 1024;
    final payload = Uint8List(chunkSize);
    for (int i = 0; i < payload.length; i++) payload[i] = i & 0xFF;

    // Set up native backpressure.
    await _dc!.setBufferedAmountLowThreshold(_kLowWater);
    int nativeBuffered = 0;
    final bufferDrain = StreamController<void>.broadcast();
    _dc!.onBufferedAmountLow.listen((_) {
      nativeBuffered = 0;
      bufferDrain.add(null);
    });

    final done = Completer<void>();
    Timer(Duration(seconds: _durationSeconds), () { if (!done.isCompleted) done.complete(); });

    final testStart = DateTime.now();
    int windowBytes = 0;
    DateTime windowStart = DateTime.now();

    final uiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final elapsed = DateTime.now().millisecondsSinceEpoch - testStart.millisecondsSinceEpoch;
      setState(() {
        _elapsedMs = elapsed;
        _progress = (elapsed / (_durationSeconds * 1000)).clamp(0.0, 1.0);
      });
    });

    while (!done.isCompleted) {
      if (nativeBuffered >= _kHighWater) {
        // Native buffer full — wait for the low-water drain event.
        try {
          await bufferDrain.stream.first.timeout(const Duration(seconds: 2));
        } catch (_) {
          break; // safety: give up if drain never arrives
        }
      }
      if (done.isCompleted) break;

      await _dc!.sendBinary(payload);
      nativeBuffered += chunkSize;
      _bytesSent += chunkSize;
      windowBytes += chunkSize;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final windowMs = nowMs - windowStart.millisecondsSinceEpoch;
      if (windowMs >= 200) {
        final rate = (windowBytes * 8) / (windowMs * 1000.0);
        if (mounted) setState(() => _rateMbps = rate);
        windowBytes = 0;
        windowStart = DateTime.now();
      }
    }

    uiTimer.cancel();
    bufferDrain.close();

    // Sentinel: empty binary marks end of test for receiver.
    try { await _dc!.sendBinary(Uint8List(0)); } catch (_) {}

    final elapsed = DateTime.now().millisecondsSinceEpoch - testStart.millisecondsSinceEpoch;
    final mbps = elapsed > 0 ? (_bytesSent * 8) / (elapsed * 1000.0) : 0.0;
    debugPrint('[Remote] sent ${(_bytesSent / 1e6).toStringAsFixed(2)} MB '
        'in ${elapsed / 1000}s = ${mbps.toStringAsFixed(2)} Mbps');

    if (mounted) setState(() {
      _phase = _Phase.done;
      _progress = 1.0;
      _elapsedMs = elapsed;
      _rateMbps = mbps;
      _status = 'Test complete';
    });
    _cleanup();
  }

  // --------------------------------------------------------------------------
  // Receiver test: count until sentinel
  // --------------------------------------------------------------------------

  Future<void> _runReceiverTest() async {
    final done = Completer<void>();
    final testStart = DateTime.now();
    int windowBytes = 0;
    DateTime windowStart = DateTime.now();

    final uiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || done.isCompleted) return;
      final elapsed = DateTime.now().millisecondsSinceEpoch - testStart.millisecondsSinceEpoch;
      setState(() {
        _elapsedMs = elapsed;
        _progress = (elapsed / (_durationSeconds * 1000)).clamp(0.0, 1.0);
      });
    });

    final msgSub = _dc!.onMessage.listen((msg) {
      if (!msg.isBinary) return;
      final data = msg.binaryData;
      if (data.isEmpty) {
        if (!done.isCompleted) done.complete(); // sentinel
        return;
      }
      _bytesReceived += data.length;
      windowBytes += data.length;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final windowMs = nowMs - windowStart.millisecondsSinceEpoch;
      if (windowMs >= 200) {
        final rate = (windowBytes * 8) / (windowMs * 1000.0);
        if (mounted) setState(() => _rateMbps = rate);
        windowBytes = 0;
        windowStart = DateTime.now();
      }
    });

    // Safety timeout: duration + 30s in case sentinel is lost.
    Timer(Duration(seconds: _durationSeconds + 30), () {
      if (!done.isCompleted) done.complete();
    });

    await done.future;
    uiTimer.cancel();
    await msgSub.cancel();

    final elapsed = DateTime.now().millisecondsSinceEpoch - testStart.millisecondsSinceEpoch;
    final mbps = elapsed > 0 ? (_bytesReceived * 8) / (elapsed * 1000.0) : 0.0;
    debugPrint('[Remote] received ${(_bytesReceived / 1e6).toStringAsFixed(2)} MB '
        'in ${elapsed / 1000}s = ${mbps.toStringAsFixed(2)} Mbps');

    if (mounted) setState(() {
      _phase = _Phase.done;
      _progress = 1.0;
      _elapsedMs = elapsed;
      _rateMbps = mbps;
      _status = 'Test complete';
    });
    _cleanup();
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final canConnect = _phase == _Phase.idle ||
        _phase == _Phase.done ||
        _phase == _Phase.error;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Settings', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _sigUrlCtrl,
                  enabled: canConnect,
                  decoration: const InputDecoration(
                    labelText: 'Signaling Server URL',
                    hintText: 'ws://192.168.1.1:8080',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _localIdCtrl,
                      enabled: canConnect,
                      decoration: const InputDecoration(
                        labelText: 'My ID',
                        hintText: 'flutter-bridge',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _remoteIdCtrl,
                      enabled: canConnect,
                      decoration: const InputDecoration(
                        labelText: 'Remote ID',
                        hintText: 'peer',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Text('Role', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true,  label: Text('Offerer (sends)'),   icon: Icon(Icons.call_made)),
                    ButtonSegment(value: false, label: Text('Answerer (receives)'), icon: Icon(Icons.call_received)),
                  ],
                  selected: {_isOfferer},
                  onSelectionChanged: canConnect
                      ? (s) => setState(() => _isOfferer = s.first)
                      : null,
                ),
                const SizedBox(height: 12),
                Text('Duration', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 5,  label: Text('5s')),
                    ButtonSegment(value: 10, label: Text('10s')),
                    ButtonSegment(value: 30, label: Text('30s')),
                  ],
                  selected: {_durationSeconds},
                  onSelectionChanged: canConnect
                      ? (s) => setState(() => _durationSeconds = s.first)
                      : null,
                ),
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
                _phaseRow(),
                const SizedBox(height: 4),
                Text(_status),
              ]),
            ),
          ),
          if (_phase == _Phase.testing) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progress,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('${(_elapsedMs / 1000).toStringAsFixed(1)}s / ${_durationSeconds}s'),
              Text('${_rateMbps.toStringAsFixed(1)} Mbps'),
            ]),
          ],
          if (_phase == _Phase.done) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Results', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _row('Role', _isOfferer ? 'Offerer (sender)' : 'Answerer (receiver)'),
                  _row('Duration', '${(_elapsedMs / 1000).toStringAsFixed(1)} s'),
                  if (_isOfferer)
                    _row('Sent', '${(_bytesSent / 1e6).toStringAsFixed(2)} MB'),
                  if (!_isOfferer)
                    _row('Received', '${(_bytesReceived / 1e6).toStringAsFixed(2)} MB'),
                  _row('Throughput', '${_rateMbps.toStringAsFixed(2)} Mbps'),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: Icon(_isOfferer ? Icons.call_made : Icons.call_received),
            label: Text(
              switch (_phase) {
                _Phase.done || _Phase.error => 'Try Again',
                _Phase.idle => _isOfferer ? 'Connect & Send' : 'Connect & Receive',
                _ => 'Working…',
              },
            ),
            onPressed: canConnect ? _connect : null,
          ),
        ],
      ),
    );
  }

  Widget _phaseRow() {
    final (color, icon) = switch (_phase) {
      _Phase.idle       => (Colors.grey,   Icons.hourglass_empty),
      _Phase.connecting => (Colors.orange, Icons.sync),
      _Phase.testing    => (Colors.blue,   Icons.speed),
      _Phase.done       => (Colors.teal,   Icons.done_all),
      _Phase.error      => (Colors.red,    Icons.error),
    };
    return Row(children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 8),
      Text(_phase.name.toUpperCase(),
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
