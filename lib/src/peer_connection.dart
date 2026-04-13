import 'data_channel.dart';
import 'event_dispatcher.dart';
import 'resource.dart';
import 'types.dart';
import 'websocket_connection.dart';

class PionPeerConnection extends PionResource {
  final void Function(String)? onLog;
  late Stream<IceCandidate> _onIceCandidate;
  late Stream<void> _onIceGatheringComplete;
  late Stream<PionDataChannel> _onDataChannel;
  late Stream<ConnectionState> _onConnectionStateChange;

  PionPeerConnection(
    String handle,
    WebSocketConnection connection,
    EventDispatcher dispatcher, {
    this.onLog,
  }) : super(handle, connection, dispatcher) {
    _setupStreams();
  }

  void _setupStreams() {
    _onIceCandidate = onEvent()
        .where((msg) => msg.type == 'event:iceCandidate')
        .map((msg) => IceCandidate(
              candidate: (msg.data['candidate'] as String?) ?? '',
              sdpMid: (msg.data['sdp_mid'] as String?) ?? '',
              sdpMlineIndex: (msg.data['sdp_mline_index'] as num?)?.toInt() ?? 0,
            ));

    _onIceGatheringComplete = onEvent()
        .where((msg) => msg.type == 'event:iceGatheringComplete')
        .map((_) => null);

    _onDataChannel = onEvent()
        .where((msg) => msg.type == 'event:dataChannel')
        .map((msg) {
          final dcLabel = (msg.data['label'] as String?) ?? '';
          onLog?.call('[PC] incoming DC label=$dcLabel');
          return PionDataChannel(
            (msg.data['dc_handle'] as String?) ?? '',
            connection,
            dispatcher,
            label: dcLabel,
            onLog: onLog,
          );
        });

    _onConnectionStateChange = onEvent()
        .where((msg) => msg.type == 'event:connectionStateChange')
        .map((msg) {
          final state = ConnectionState.fromString((msg.data['state'] as String?) ?? 'new');
          onLog?.call('[PC] connectionState=$state');
          return state;
        });
  }

  Stream<IceCandidate> get onIceCandidate => _onIceCandidate;
  Stream<void> get onIceGatheringComplete => _onIceGatheringComplete;
  Stream<PionDataChannel> get onDataChannel => _onDataChannel;
  Stream<ConnectionState> get onConnectionStateChange =>
      _onConnectionStateChange;

  Future<String> createOffer({Map<String, dynamic>? options}) async {
    final response = await request('pc:offer', {
      'offer_options': options ?? {},
    });
    return response['sdp'] as String;
  }

  Future<String> createAnswer({Map<String, dynamic>? options}) async {
    final response = await request('pc:answer', {
      'answer_options': options ?? {},
    });
    return response['sdp'] as String;
  }

  Future<void> setLocalDescription(String sdp, String type) async {
    await request('pc:setLocalDesc', {
      'sdp': sdp,
      'type': type,
    });
  }

  Future<void> setRemoteDescription(String sdp, String type) async {
    await request('pc:setRemoteDesc', {
      'sdp': sdp,
      'type': type,
    });
  }

  Future<void> addIceCandidate(IceCandidate candidate) async {
    await request('pc:addIce', {
      'candidate': candidate.candidate,
      'sdp_mid': candidate.sdpMid,
      'sdp_mline_index': candidate.sdpMlineIndex,
    });
  }

  Future<PionDataChannel> createDataChannel(
    String label, {
    bool ordered = true,
    int? maxRetransmits,
    int? maxPacketLifetimeMs,
  }) async {
    final response = await request('pc:createDc', {
      'label': label,
      'options': {
        'ordered': ordered,
        if (maxRetransmits != null) 'max_retransmits': maxRetransmits,
        if (maxPacketLifetimeMs != null)
          'max_packet_lifetime_ms': maxPacketLifetimeMs,
      },
    });
    onLog?.call('[PC] createDataChannel label=$label');
    return PionDataChannel(
      response['dc_handle'] as String,
      connection,
      dispatcher,
      label: label,
      onLog: onLog,
    );
  }
}
