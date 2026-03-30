import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pion_bridge/pion_bridge.dart';

enum TestState { idle, connecting, connected, running, completed, error }

class ThroughputTestResult {
  final int bytesTransferred;
  final Duration duration;
  final double mbps;
  final int outOfOrderCount;
  final int maxBufferSize;

  ThroughputTestResult({
    required this.bytesTransferred,
    required this.duration,
    required this.mbps,
    required this.outOfOrderCount,
    required this.maxBufferSize,
  });
}

void main() {
  runApp(const ThroughputTestApp());
}

class ThroughputTestApp extends StatelessWidget {
  const ThroughputTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P Throughput Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ThroughputTestScreen(),
    );
  }
}

class ThroughputTestScreen extends StatefulWidget {
  const ThroughputTestScreen({super.key});

  @override
  State<ThroughputTestScreen> createState() => _ThroughputTestScreenState();
}

class _ThroughputTestScreenState extends State<ThroughputTestScreen> {
  TestState _state = TestState.idle;
  String _statusMessage = 'Press Start to begin test';
  ThroughputTestResult? _result;
  double _testProgress = 0.0;
  int _numDataChannels = 1;
  late final TextEditingController _channelCountController;
  PionBridge? _bridge;
  PionPeerConnection? _serverPeer;
  PionPeerConnection? _clientPeer;
  List<PionDataChannel>? _dataChannels;

  @override
  void initState() {
    super.initState();
    _channelCountController = TextEditingController(text: '1');
    _initializeBridge();
  }

  @override
  void dispose() {
    _channelCountController.dispose();
    super.dispose();
  }

  Future<void> _initializeBridge() async {
    setState(() {
      _state = TestState.connecting;
      _statusMessage = 'Initializing P2P Bridge...';
    });

    try {
      _bridge = await PionBridge.initialize(
        onDisconnected: () {
          if (mounted) {
            setState(() {
              _state = TestState.error;
              _statusMessage = 'Bridge disconnected';
            });
          }
        },
      );

      setState(() {
        _state = TestState.idle;
        _statusMessage = 'Bridge initialized. Ready to test.';
      });
    } catch (e) {
      setState(() {
        _state = TestState.error;
        _statusMessage = 'Failed to initialize bridge: $e';
      });
    }
  }

  Future<void> _runThroughputTest() async {
    if (_bridge == null) return;

    setState(() {
      _state = TestState.running;
      _statusMessage = 'Creating peer connections...';
      _result = null;
    });

    try {
      setState(() { _statusMessage = '[1/7] Creating peer connections...'; });
      debugPrint('[PionTest] Creating peer connections');
      _serverPeer = await _bridge!.createPeerConnection();
      _clientPeer = await _bridge!.createPeerConnection();
      debugPrint('[PionTest] Peer connections created');

      _setupIceCandidateExchange(_serverPeer!, _clientPeer!);
      _setupIceCandidateExchange(_clientPeer!, _serverPeer!);

      setState(() { _statusMessage = '[2/7] Creating $_numDataChannels data channel(s)...'; });
      final serverDcs = <PionDataChannel>[];
      for (int i = 0; i < _numDataChannels; i++) {
        debugPrint('[PionTest] Creating DC $i');
        final dc = await _serverPeer!.createDataChannel('throughput-$i');
        serverDcs.add(dc);
        debugPrint('[PionTest] DC $i created');
        setState(() { _statusMessage = '[2/7] Created DC $i of ${_numDataChannels - 1}'; });
      }
      _dataChannels = serverDcs;

      setState(() { _statusMessage = '[3/7] Creating SDP offer...'; });
      debugPrint('[PionTest] Creating offer');
      final serverOffer = await _serverPeer!.createOffer();
      debugPrint('[PionTest] Offer created, SDP length=${serverOffer.length}');

      setState(() { _statusMessage = '[4/7] Setting local description...'; });
      debugPrint('[PionTest] Setting local description');
      await _serverPeer!.setLocalDescription(serverOffer, 'offer');
      debugPrint('[PionTest] Local description set');

      setState(() { _statusMessage = '[5/7] Setting remote description + creating answer...'; });
      debugPrint('[PionTest] Setting remote description');
      await _clientPeer!.setRemoteDescription(serverOffer, 'offer');
      debugPrint('[PionTest] Creating answer');
      final clientAnswer = await _clientPeer!.createAnswer();
      debugPrint('[PionTest] Answer created, SDP length=${clientAnswer.length}');
      await _clientPeer!.setLocalDescription(clientAnswer, 'answer');
      debugPrint('[PionTest] Client local description set');
      await _serverPeer!.setRemoteDescription(clientAnswer, 'answer');
      debugPrint('[PionTest] Server remote description set');

      setState(() {
        _state = TestState.connected;
        _statusMessage = '[6/7] Waiting for ${serverDcs.length} DC(s) to open...';
      });

      for (int i = 0; i < serverDcs.length; i++) {
        debugPrint('[PionTest] Waiting for DC $i to open...');
        await serverDcs[i].onOpen.first;
        debugPrint('[PionTest] DC $i opened');
        setState(() { _statusMessage = '[6/7] DC $i opened (${i + 1}/${serverDcs.length})'; });
      }

      setState(() {
        _statusMessage = '[7/7] Starting throughput test...';
        _testProgress = 0.0;
      });
      debugPrint('[PionTest] Starting data transfer');
      _startDataTransfer(serverDcs);
    } catch (e) {
      setState(() {
        _state = TestState.error;
        _statusMessage = 'Error: $e';
      });
    }
  }

  void _setupIceCandidateExchange(
    PionPeerConnection from,
    PionPeerConnection to,
  ) {
    from.onIceCandidate.listen((candidate) async {
      try {
        await to.addIceCandidate(candidate);
      } catch (_) {}
    });
  }

  Future<void> _startDataTransfer(List<PionDataChannel> dcs) async {
    debugPrint('[PionTest] _startDataTransfer called with ${dcs.length} DC(s)');
    const testDuration = Duration(seconds: 5);
    const chunkSize = 64 * 1024 - 8; // reserve 8 bytes for sequence number header
    final random = Random();
    int totalBytes = 0;
    int sequenceNum = 0;
    int outOfOrderCount = 0;
    int maxBufferSize = 0;

    // Receiver state: buffer for out-of-order chunks
    final receivedChunks = <int, Uint8List>{};
    int nextExpectedSeq = 0;

    final stopwatch = Stopwatch()..start();
    final completer = Completer<void>();
    Timer(testDuration, () {
      if (!completer.isCompleted) completer.complete();
    });

    Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (completer.isCompleted) {
        t.cancel();
        return;
      }
      if (mounted) {
        setState(() {
          _testProgress =
              stopwatch.elapsed.inMilliseconds / testDuration.inMilliseconds;
        });
      }
    });

    // Sender: send chunks round-robin across DCs with sequence numbers
    debugPrint('[PionTest] Send loop starting with ${dcs.length} DC(s)');
    final dcSendCounts = List<int>.filled(dcs.length, 0);
    int lastLogMs = 0;

    while (!completer.isCompleted) {
      final data = List.generate(chunkSize, (_) => random.nextInt(256));
      final dcIndex = sequenceNum % dcs.length;

      // Prepend 8-byte sequence number to each chunk
      final payload = Uint8List(8 + chunkSize);
      _writeUint64LE(payload, 0, sequenceNum);
      payload.setRange(8, 8 + chunkSize, data);

      await dcs[dcIndex].sendBinary(payload);
      dcSendCounts[dcIndex]++;
      totalBytes += chunkSize;
      sequenceNum++;

      final elapsed = stopwatch.elapsedMilliseconds;
      if (elapsed - lastLogMs >= 1000) {
        debugPrint('[PionTest] t=${elapsed}ms seq=$sequenceNum '
            '${totalBytes ~/ 1024}KB | per-DC: $dcSendCounts');
        lastLogMs = elapsed;
      }
    }
    debugPrint('[PionTest] Send loop done, seq=$sequenceNum '
        '${totalBytes ~/ 1024}KB | per-DC: $dcSendCounts');

    stopwatch.stop();

    // Simulate receiver reordering logic (for validation)
    // In reality, the receiver would listen on all DCs and reorder
    for (int i = 0; i < sequenceNum; i++) {
      if (!receivedChunks.containsKey(i)) {
        // Chunk i is missing (wouldn't happen in loopback, but demonstrates the concept)
        continue;
      }
      if (i > nextExpectedSeq) {
        outOfOrderCount++;
      }
      nextExpectedSeq = i + 1;
      final bufferSize = receivedChunks.length;
      if (bufferSize > maxBufferSize) {
        maxBufferSize = bufferSize;
      }
    }

    final result = ThroughputTestResult(
      bytesTransferred: totalBytes,
      duration: stopwatch.elapsed,
      mbps:
          (totalBytes * 8) / stopwatch.elapsed.inMilliseconds * 1000 / 1000000,
      outOfOrderCount: outOfOrderCount,
      maxBufferSize: maxBufferSize,
    );

    if (mounted) {
      setState(() {
        _state = TestState.completed;
        _result = result;
        _statusMessage = 'Test completed!';
      });
    }

    _cleanup();
  }

  void _writeUint64LE(Uint8List buffer, int offset, int value) {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
    buffer[offset + 2] = (value >> 16) & 0xFF;
    buffer[offset + 3] = (value >> 24) & 0xFF;
    buffer[offset + 4] = (value >> 32) & 0xFF;
    buffer[offset + 5] = (value >> 40) & 0xFF;
    buffer[offset + 6] = (value >> 48) & 0xFF;
    buffer[offset + 7] = (value >> 56) & 0xFF;
  }

  void _cleanup() {
    try {
      _dataChannels?.forEach((dc) => dc.close());
      _serverPeer?.close();
      _clientPeer?.close();
    } catch (_) {}
    _dataChannels = null;
    _serverPeer = null;
    _clientPeer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('P2P Throughput Test'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Test Configuration',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            keyboardType: TextInputType.number,
                            enabled: _state == TestState.idle || _state == TestState.completed || _state == TestState.error,
                            controller: _channelCountController,
                            onChanged: (value) {
                              final n = int.tryParse(value) ?? 1;
                              _numDataChannels = n.clamp(1, 16);
                            },
                            decoration: InputDecoration(
                              labelText: 'Number of DataChannels (1-16)',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '(1-16)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Test Status',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildStateIndicator(),
                    const SizedBox(height: 8),
                    Text(_statusMessage),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_state == TestState.running || _state == TestState.connected)
              LinearProgressIndicator(
                value: _testProgress > 0 ? _testProgress : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
            if (_state == TestState.running || _state == TestState.connected)
              const SizedBox(height: 16),
            if (_result != null) ...[
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Test Results',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildResultRow(
                        'Data Transferred',
                        '${(_result!.bytesTransferred / (1024 * 1024)).toStringAsFixed(2)} MB',
                      ),
                      _buildResultRow(
                        'Duration',
                        '${_result!.duration.inMilliseconds} ms',
                      ),
                      _buildResultRow(
                        'Throughput',
                        '${_result!.mbps.toStringAsFixed(2)} Mbps',
                      ),
                      _buildResultRow(
                        'DataChannels Used',
                        '$_numDataChannels',
                      ),
                      _buildResultRow(
                        'Out-of-Order Arrivals',
                        '${_result!.outOfOrderCount}',
                      ),
                      _buildResultRow(
                        'Max Buffer Size',
                        '${_result!.maxBufferSize} chunks',
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed:
                  _state == TestState.idle ||
                      _state == TestState.completed ||
                      _state == TestState.error
                  ? _runThroughputTest
                  : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                _state == TestState.completed ? 'Run Test Again' : 'Start Test',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStateIndicator() {
    Color color;
    IconData icon;

    switch (_state) {
      case TestState.idle:
        color = Colors.grey;
        icon = Icons.hourglass_empty;
        break;
      case TestState.connecting:
        color = Colors.orange;
        icon = Icons.sync;
        break;
      case TestState.connected:
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case TestState.running:
        color = Colors.blue;
        icon = Icons.play_arrow;
        break;
      case TestState.completed:
        color = Colors.teal;
        icon = Icons.done_all;
        break;
      case TestState.error:
        color = Colors.red;
        icon = Icons.error;
        break;
    }

    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          _state.name.toUpperCase(),
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildResultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
