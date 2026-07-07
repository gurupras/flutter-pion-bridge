import 'dart:async';

import 'buffered_broadcast.dart';
import 'data_channel.dart';
import 'event_dispatcher.dart';
import 'resource.dart';
import 'types.dart';
import 'websocket_connection.dart';
import 'ws_message.dart';

class PionPeerConnection extends PionResource {
  final void Function(String)? onLog;

  // One eager subscription fans out into a buffered stream per event type;
  // see BufferedBroadcast for why (subscription-order-independent delivery).
  late final StreamSubscription<WsMessage> _eventSub;
  final _iceCandidate = BufferedBroadcast<IceCandidate>();
  final _iceGatheringComplete = BufferedBroadcast<void>();
  final _dataChannel = BufferedBroadcast<PionDataChannel>();
  final _connectionStateChange = BufferedBroadcast<ConnectionState>();

  // Children (created AND received DataChannels), so closing the PC releases
  // their local stream state too — mirroring the Go registry's cascade.
  final List<PionDataChannel> _children = [];

  PionPeerConnection(
    String handle,
    WebSocketConnection connection,
    EventDispatcher dispatcher, {
    this.onLog,
  }) : super(handle, connection, dispatcher) {
    _eventSub = onEvent().listen(_route);
  }

  void _route(WsMessage msg) {
    switch (msg.type) {
      case 'event:iceCandidate':
        _iceCandidate.add(IceCandidate(
          candidate: (msg.data['candidate'] as String?) ?? '',
          sdpMid: (msg.data['sdp_mid'] as String?) ?? '',
          sdpMlineIndex: (msg.data['sdp_mline_index'] as num?)?.toInt() ?? 0,
        ));
      case 'event:iceGatheringComplete':
        _iceGatheringComplete.add(null);
      case 'event:dataChannel':
        final dcLabel = (msg.data['label'] as String?) ?? '';
        onLog?.call('[PC] incoming DC label=$dcLabel');
        final dc = PionDataChannel(
          (msg.data['dc_handle'] as String?) ?? '',
          connection,
          dispatcher,
          label: dcLabel,
          onLog: onLog,
        );
        _children.add(dc);
        _dataChannel.add(dc);
      case 'event:connectionStateChange':
        final state =
            ConnectionState.fromString((msg.data['state'] as String?) ?? 'new');
        onLog?.call('[PC] connectionState=$state');
        _connectionStateChange.add(state);
    }
  }

  Stream<IceCandidate> get onIceCandidate => _iceCandidate.stream;
  Stream<void> get onIceGatheringComplete => _iceGatheringComplete.stream;
  Stream<PionDataChannel> get onDataChannel => _dataChannel.stream;
  Stream<ConnectionState> get onConnectionStateChange =>
      _connectionStateChange.stream;

  @override
  bool disposeLocal() {
    if (!super.disposeLocal()) return false;
    _eventSub.cancel();
    // Cascade to children: the server tears their handles down with the
    // parent's resource:delete, so only local stream state needs releasing.
    for (final child in _children) {
      child.disposeLocal();
    }
    _children.clear();
    _iceCandidate.close();
    _iceGatheringComplete.close();
    _dataChannel.close();
    _connectionStateChange.close();
    return true;
  }

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
    final dc = PionDataChannel(
      response['dc_handle'] as String,
      connection,
      dispatcher,
      label: label,
      onLog: onLog,
    );
    _children.add(dc);
    return dc;
  }
}
