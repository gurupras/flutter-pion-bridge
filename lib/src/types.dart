import 'dart:convert';
import 'dart:typed_data';

/// Connection details for an already-running pion bridge server.
///
/// Returned by [PionBridge.startServer] (which must run on the root isolate)
/// and consumed by [PionBridge.connectExisting] (which can run on any
/// isolate). Send across isolate boundaries via `SendPort.send`.
class PionServerEndpoint {
  final int port;
  final String token;

  const PionServerEndpoint({required this.port, required this.token});

  Map<String, dynamic> toMap() => {'port': port, 'token': token};

  factory PionServerEndpoint.fromMap(Map<dynamic, dynamic> map) =>
      PionServerEndpoint(
        port: map['port'] as int,
        token: map['token'] as String,
      );
}

class IceServer {
  final List<String> urls;
  final String? username;
  final String? credential;

  IceServer({
    required this.urls,
    this.username,
    this.credential,
  });

  Map<String, dynamic> toMap() => {
        'urls': urls,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      };
}

class IceCandidate {
  final String candidate;
  final String sdpMid;
  final int sdpMlineIndex;

  IceCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMlineIndex,
  });
}

class DataChannelMessage {
  final Uint8List bytes;
  final bool isBinary;

  DataChannelMessage({required this.bytes, required this.isBinary});

  /// The payload decoded as UTF-8. Malformed sequences are replaced with
  /// U+FFFD instead of throwing — check [isBinary] before treating a frame
  /// as text.
  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// Per-DataChannel send tunables sent in the `init` message.
///
/// All fields are optional; omitted fields keep the server-side defaults
/// ([DCConfig.DefaultDCConfig] in Go: 512 KB low-water threshold, queue
/// depth 32).  Individual channels can further adjust the buffer threshold
/// at runtime via [PionDataChannel.setBufferedAmountLowThreshold].
class PionDCConfig {
  /// Low-water mark in bytes for the native send buffer.  The [PionDataChannel.sendBinary]
  /// ack (when `awaitDrain` is true) is held until pion's buffer drains to
  /// at or below this value.  Default: 512 KB.
  final int? bufferedAmountLowThreshold;

  /// Capacity of the per-DC work channel on the Go side.  Must be >= 1.
  /// Default: 32.
  final int? sendQueueDepth;

  const PionDCConfig({
    this.bufferedAmountLowThreshold,
    this.sendQueueDepth,
  });

  Map<String, dynamic> toMap() => {
        if (bufferedAmountLowThreshold != null)
          'buffered_amount_low_threshold': bufferedAmountLowThreshold,
        if (sendQueueDepth != null) 'send_queue_depth': sendQueueDepth,
      };
}

/// Configuration for the pion SettingEngine, sent in the [PionBridge.initialize]
/// call. All fields are optional; only non-null values are sent to the Go side.
///
/// Serializable settings only — function-typed settings (SetInterfaceFilter,
/// SetIPFilter, SetVNet, etc.) cannot cross the wire and are not supported.
///
/// Paired settings that must be provided together:
/// - [ephemeralUdpPortMin] and [ephemeralUdpPortMax]
/// - [iceDisconnectedTimeoutMs], [iceFailedTimeoutMs], and [iceKeepaliveMs]
class PionSettingsEngine {
  // Boolean flags
  final bool? disableActiveTcp;
  final bool? disableCertificateFingerprintVerification;
  final bool? disableCloseByDtls;
  final bool? disableSrtcpReplayProtection;
  final bool? disableSrtpReplayProtection;

  /// Detach every DataChannel (pion's `DetachDataChannels`). The Go side then
  /// reads and writes each channel directly instead of through pion's
  /// callback read loop. The Dart API is unchanged: messages still arrive on
  /// [PionDataChannel.onMessage] and sends still go through `send`/`sendBinary`.
  ///
  /// Applies to every channel on connections created by this bridge, which is
  /// pion's granularity. Useful for bulk transfer, together with
  /// [enableDataChannelBlockWrite] and a larger [sctpMaxReceiveBufferSize].
  final bool? detachDataChannels;

  /// Make writes on detached channels block while the SCTP send buffer is
  /// full (pion's `EnableDataChannelBlockWrite`), so a sender is paced by the
  /// transport instead of queueing in pion. **Only takes effect together with
  /// [detachDataChannels]**; without it pion ignores the setting.
  final bool? enableDataChannelBlockWrite;
  final bool? enableSctpZeroChecksum;

  /// Enable per-second pipeline tracing to stderr inside the Go bridge process.
  /// Records frame rates, throughput, and dc.Send() latency per DataChannel.
  /// Off by default — only enable for diagnostics; has measurable overhead.
  final bool? enableTracing;

  // Numeric settings
  final int? sctpMaxReceiveBufferSize;
  final int? sctpMaxMessageSize;
  final int? sctpMinCwnd;
  final int? sctpCwndCaStep;
  final int? receiveMtu;
  final int? iceMaxBindingRequests;
  final int? dtlsReplayProtectionWindow;
  final int? srtcpReplayProtectionWindow;
  final int? srtpReplayProtectionWindow;

  /// Must be provided together with [ephemeralUdpPortMax].
  final int? ephemeralUdpPortMin;

  /// Must be provided together with [ephemeralUdpPortMin].
  final int? ephemeralUdpPortMax;

  final int? sctpRtoMaxMs;

  // Duration settings (milliseconds)

  /// Must be provided together with [iceFailedTimeoutMs] and [iceKeepaliveMs].
  final int? iceDisconnectedTimeoutMs;

  /// Must be provided together with [iceDisconnectedTimeoutMs] and [iceKeepaliveMs].
  final int? iceFailedTimeoutMs;

  /// Must be provided together with [iceDisconnectedTimeoutMs] and [iceFailedTimeoutMs].
  final int? iceKeepaliveMs;

  final int? hostAcceptanceMinWaitMs;
  final int? srflxAcceptanceMinWaitMs;
  final int? prflxAcceptanceMinWaitMs;
  final int? relayAcceptanceMinWaitMs;
  final int? dtlsRetransmissionIntervalMs;
  final int? stunGatherTimeoutMs;

  // String settings
  final String? multicastDnsHostName;

  /// Restricts ICE gathering to the named network interfaces (e.g. `['lo']`
  /// or `['eth0', 'wlan0']`). When null, all interfaces are used. Combine
  /// with [includeLoopbackCandidate] for loopback-only operation (loopback
  /// candidates are excluded by default per the ICE spec).
  final List<String>? interfaceWhitelist;

  /// Includes loopback (127.0.0.1) host candidates in ICE gathering.
  final bool? includeLoopbackCandidate;

  /// DataChannel send tunables.  Overrides the server-side defaults for every
  /// DataChannel created through this bridge session.
  final PionDCConfig? dcConfig;

  const PionSettingsEngine({
    this.disableActiveTcp,
    this.disableCertificateFingerprintVerification,
    this.disableCloseByDtls,
    this.disableSrtcpReplayProtection,
    this.disableSrtpReplayProtection,
    this.detachDataChannels,
    this.enableDataChannelBlockWrite,
    this.enableSctpZeroChecksum,
    this.enableTracing,
    this.sctpMaxReceiveBufferSize,
    this.sctpMaxMessageSize,
    this.sctpMinCwnd,
    this.sctpCwndCaStep,
    this.receiveMtu,
    this.iceMaxBindingRequests,
    this.dtlsReplayProtectionWindow,
    this.srtcpReplayProtectionWindow,
    this.srtpReplayProtectionWindow,
    this.ephemeralUdpPortMin,
    this.ephemeralUdpPortMax,
    this.iceDisconnectedTimeoutMs,
    this.iceFailedTimeoutMs,
    this.iceKeepaliveMs,
    this.sctpRtoMaxMs,
    this.hostAcceptanceMinWaitMs,
    this.srflxAcceptanceMinWaitMs,
    this.prflxAcceptanceMinWaitMs,
    this.relayAcceptanceMinWaitMs,
    this.dtlsRetransmissionIntervalMs,
    this.stunGatherTimeoutMs,
    this.multicastDnsHostName,
    this.interfaceWhitelist,
    this.includeLoopbackCandidate,
    this.dcConfig,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    if (disableActiveTcp != null) map['disable_active_tcp'] = disableActiveTcp;
    if (disableCertificateFingerprintVerification != null) {
      map['disable_certificate_fingerprint_verification'] =
          disableCertificateFingerprintVerification;
    }
    if (disableCloseByDtls != null)
      map['disable_close_by_dtls'] = disableCloseByDtls;
    if (disableSrtcpReplayProtection != null) {
      map['disable_srtcp_replay_protection'] = disableSrtcpReplayProtection;
    }
    if (disableSrtpReplayProtection != null) {
      map['disable_srtp_replay_protection'] = disableSrtpReplayProtection;
    }
    if (detachDataChannels != null) {
      map['detach_data_channels'] = detachDataChannels;
    }
    if (enableDataChannelBlockWrite != null) {
      map['enable_data_channel_block_write'] = enableDataChannelBlockWrite;
    }
    if (enableSctpZeroChecksum != null)
      map['enable_sctp_zero_checksum'] = enableSctpZeroChecksum;
    if (enableTracing == true) map['enable_tracing'] = true;
    if (sctpMaxReceiveBufferSize != null) {
      map['sctp_max_receive_buffer_size'] = sctpMaxReceiveBufferSize;
    }
    if (sctpMaxMessageSize != null)
      map['sctp_max_message_size'] = sctpMaxMessageSize;
    if (sctpMinCwnd != null) map['sctp_min_cwnd'] = sctpMinCwnd;
    if (sctpCwndCaStep != null) map['sctp_cwnd_ca_step'] = sctpCwndCaStep;
    if (receiveMtu != null) map['receive_mtu'] = receiveMtu;
    if (iceMaxBindingRequests != null)
      map['ice_max_binding_requests'] = iceMaxBindingRequests;
    if (dtlsReplayProtectionWindow != null) {
      map['dtls_replay_protection_window'] = dtlsReplayProtectionWindow;
    }
    if (srtcpReplayProtectionWindow != null) {
      map['srtcp_replay_protection_window'] = srtcpReplayProtectionWindow;
    }
    if (srtpReplayProtectionWindow != null) {
      map['srtp_replay_protection_window'] = srtpReplayProtectionWindow;
    }
    if (ephemeralUdpPortMin != null)
      map['ephemeral_udp_port_min'] = ephemeralUdpPortMin;
    if (ephemeralUdpPortMax != null)
      map['ephemeral_udp_port_max'] = ephemeralUdpPortMax;
    if (iceDisconnectedTimeoutMs != null) {
      map['ice_disconnected_timeout_ms'] = iceDisconnectedTimeoutMs;
    }
    if (iceFailedTimeoutMs != null)
      map['ice_failed_timeout_ms'] = iceFailedTimeoutMs;
    if (iceKeepaliveMs != null) map['ice_keepalive_ms'] = iceKeepaliveMs;
    if (sctpRtoMaxMs != null) map['sctp_rto_max_ms'] = sctpRtoMaxMs;
    if (hostAcceptanceMinWaitMs != null)
      map['host_acceptance_min_wait_ms'] = hostAcceptanceMinWaitMs;
    if (srflxAcceptanceMinWaitMs != null) {
      map['srflx_acceptance_min_wait_ms'] = srflxAcceptanceMinWaitMs;
    }
    if (prflxAcceptanceMinWaitMs != null) {
      map['prflx_acceptance_min_wait_ms'] = prflxAcceptanceMinWaitMs;
    }
    if (relayAcceptanceMinWaitMs != null)
      map['relay_acceptance_min_wait_ms'] = relayAcceptanceMinWaitMs;
    if (dtlsRetransmissionIntervalMs != null) {
      map['dtls_retransmission_interval_ms'] = dtlsRetransmissionIntervalMs;
    }
    if (stunGatherTimeoutMs != null)
      map['stun_gather_timeout_ms'] = stunGatherTimeoutMs;
    if (multicastDnsHostName != null)
      map['multicast_dns_host_name'] = multicastDnsHostName;
    if (interfaceWhitelist != null)
      map['interface_whitelist'] = interfaceWhitelist;
    if (includeLoopbackCandidate != null) {
      map['include_loopback_candidate'] = includeLoopbackCandidate;
    }
    final dc = dcConfig;
    if (dc != null) {
      final dcMap = dc.toMap();
      if (dcMap.isNotEmpty) map['dc_config'] = dcMap;
    }
    return map;
  }
}

enum ConnectionState {
  newConnection,
  connecting,
  connected,
  disconnected,
  failed,
  closed;

  static ConnectionState fromString(String state) {
    if (state == 'new') return ConnectionState.newConnection;
    return ConnectionState.values.byName(state);
  }
}

/// Codecs a PeerConnection's API registers, in preference order (the order
/// they appear in SDP). Without one, a connection has no media codecs, which is
/// all a data-channel-only application needs. Registering codecs also registers
/// pion's default interceptors (NACK, RTCP reports).
///
/// Names: video `AV1`, `VP9`, `VP8`; audio `opus`. Unknown names fail with
/// `INVALID_MEDIA_ENGINE`.
class PionMediaEngine {
  final List<String> videoCodecs;
  final List<String> audioCodecs;

  /// How often missing packets are NACKed. Null keeps pion's 100 ms; a
  /// receiver without a jitter buffer wants retransmissions sooner.
  final int? nackIntervalMs;

  const PionMediaEngine({
    this.videoCodecs = const [],
    this.audioCodecs = const [],
    this.nackIntervalMs,
  });

  Map<String, dynamic> toMap() => {
        'video_codecs': videoCodecs,
        'audio_codecs': audioCodecs,
        if (nackIntervalMs != null) 'nack_interval_ms': nackIntervalMs,
      };
}

enum MediaKind { video, audio }

enum TransceiverDirection {
  sendrecv,
  sendonly,
  recvonly,
  inactive,
}

/// A remote track that arrived on a PeerConnection. Media itself is not
/// delivered to Dart: an application reads it in Go, linked into the same
/// shared library and registered with the bridge's `embed` package.
class RemoteTrack {
  final MediaKind kind;
  final String trackId;
  final String streamId;

  /// MIME type, e.g. `video/AV1`.
  final String codec;

  const RemoteTrack({
    required this.kind,
    required this.trackId,
    required this.streamId,
    required this.codec,
  });
}
