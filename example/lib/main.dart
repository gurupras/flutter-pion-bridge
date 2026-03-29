import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:pion_bridge/pion_bridge.dart';

enum TestState { idle, connecting, connected, running, completed, error }

class ThroughputTestResult {
  final int bytesTransferred;
  final Duration duration;
  final double mbps;

  ThroughputTestResult({
    required this.bytesTransferred,
    required this.duration,
    required this.mbps,
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
  PionBridge? _bridge;
  PionPeerConnection? _serverPeer;
  PionPeerConnection? _clientPeer;
  PionDataChannel? _dataChannel;

  @override
  void initState() {
    super.initState();
    _initializeBridge();
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
      _serverPeer = await _bridge!.createPeerConnection();
      _clientPeer = await _bridge!.createPeerConnection();

      _setupIceCandidateExchange(_serverPeer!, _clientPeer!);
      _setupIceCandidateExchange(_clientPeer!, _serverPeer!);

      // Create data channel on the offering peer before creating the offer,
      // so the SDP includes an m=application section with ICE credentials.
      setState(() { _statusMessage = 'Creating data channel...'; });
      final serverDc = await _serverPeer!.createDataChannel('throughput');
      _dataChannel = serverDc;

      setState(() { _statusMessage = 'Creating SDP offer...'; });
      final serverOffer = await _serverPeer!.createOffer();
      await _serverPeer!.setLocalDescription(serverOffer, 'offer');

      await _clientPeer!.setRemoteDescription(serverOffer, 'offer');
      final clientAnswer = await _clientPeer!.createAnswer();
      await _clientPeer!.setLocalDescription(clientAnswer, 'answer');

      await _serverPeer!.setRemoteDescription(clientAnswer, 'answer');

      setState(() {
        _state = TestState.connected;
        _statusMessage = 'Waiting for data channel to open...';
      });

      await serverDc.onOpen.first;

      setState(() {
        _statusMessage = 'Starting throughput test...';
        _testProgress = 0.0;
      });
      _startDataTransfer(serverDc);
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

  Future<void> _startDataTransfer(PionDataChannel dc) async {
    const testDuration = Duration(seconds: 5);
    const chunkSize = 64 * 1024;
    final random = Random();
    int totalBytes = 0;

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

    while (!completer.isCompleted) {
      final data = List.generate(chunkSize, (_) => random.nextInt(256));
      await dc.sendBinary(data);
      totalBytes += chunkSize;
    }

    stopwatch.stop();

    final result = ThroughputTestResult(
      bytesTransferred: totalBytes,
      duration: stopwatch.elapsed,
      mbps:
          (totalBytes * 8) / stopwatch.elapsed.inMilliseconds * 1000 / 1000000,
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

  void _cleanup() {
    try {
      _dataChannel?.close();
      _serverPeer?.close();
      _clientPeer?.close();
    } catch (_) {}
    _dataChannel = null;
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
      body: Padding(
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
                    ],
                  ),
                ),
              ),
            ],
            const Spacer(),
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
