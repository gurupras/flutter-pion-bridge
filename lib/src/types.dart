import 'dart:convert';

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
  final String data;
  final bool isBinary;

  DataChannelMessage({required this.data, required this.isBinary});

  List<int> get binaryData => base64Decode(data);
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
  final bool? enableDataChannelBlockWrite;
  final bool? enableSctpZeroChecksum;

  // Numeric settings
  final int? sctpMaxReceiveBufferSize;
  final int? sctpMaxMessageSize;
  final int? receiveMtu;
  final int? iceMaxBindingRequests;
  final int? dtlsReplayProtectionWindow;
  final int? srtcpReplayProtectionWindow;
  final int? srtpReplayProtectionWindow;

  /// Must be provided together with [ephemeralUdpPortMax].
  final int? ephemeralUdpPortMin;

  /// Must be provided together with [ephemeralUdpPortMin].
  final int? ephemeralUdpPortMax;

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

  const PionSettingsEngine({
    this.disableActiveTcp,
    this.disableCertificateFingerprintVerification,
    this.disableCloseByDtls,
    this.disableSrtcpReplayProtection,
    this.disableSrtpReplayProtection,
    this.enableDataChannelBlockWrite,
    this.enableSctpZeroChecksum,
    this.sctpMaxReceiveBufferSize,
    this.sctpMaxMessageSize,
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
    this.hostAcceptanceMinWaitMs,
    this.srflxAcceptanceMinWaitMs,
    this.prflxAcceptanceMinWaitMs,
    this.relayAcceptanceMinWaitMs,
    this.dtlsRetransmissionIntervalMs,
    this.stunGatherTimeoutMs,
    this.multicastDnsHostName,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    if (disableActiveTcp != null) map['disable_active_tcp'] = disableActiveTcp;
    if (disableCertificateFingerprintVerification != null) {
      map['disable_certificate_fingerprint_verification'] =
          disableCertificateFingerprintVerification;
    }
    if (disableCloseByDtls != null) map['disable_close_by_dtls'] = disableCloseByDtls;
    if (disableSrtcpReplayProtection != null) {
      map['disable_srtcp_replay_protection'] = disableSrtcpReplayProtection;
    }
    if (disableSrtpReplayProtection != null) {
      map['disable_srtp_replay_protection'] = disableSrtpReplayProtection;
    }
    if (enableDataChannelBlockWrite != null) {
      map['enable_data_channel_block_write'] = enableDataChannelBlockWrite;
    }
    if (enableSctpZeroChecksum != null) map['enable_sctp_zero_checksum'] = enableSctpZeroChecksum;
    if (sctpMaxReceiveBufferSize != null) {
      map['sctp_max_receive_buffer_size'] = sctpMaxReceiveBufferSize;
    }
    if (sctpMaxMessageSize != null) map['sctp_max_message_size'] = sctpMaxMessageSize;
    if (receiveMtu != null) map['receive_mtu'] = receiveMtu;
    if (iceMaxBindingRequests != null) map['ice_max_binding_requests'] = iceMaxBindingRequests;
    if (dtlsReplayProtectionWindow != null) {
      map['dtls_replay_protection_window'] = dtlsReplayProtectionWindow;
    }
    if (srtcpReplayProtectionWindow != null) {
      map['srtcp_replay_protection_window'] = srtcpReplayProtectionWindow;
    }
    if (srtpReplayProtectionWindow != null) {
      map['srtp_replay_protection_window'] = srtpReplayProtectionWindow;
    }
    if (ephemeralUdpPortMin != null) map['ephemeral_udp_port_min'] = ephemeralUdpPortMin;
    if (ephemeralUdpPortMax != null) map['ephemeral_udp_port_max'] = ephemeralUdpPortMax;
    if (iceDisconnectedTimeoutMs != null) {
      map['ice_disconnected_timeout_ms'] = iceDisconnectedTimeoutMs;
    }
    if (iceFailedTimeoutMs != null) map['ice_failed_timeout_ms'] = iceFailedTimeoutMs;
    if (iceKeepaliveMs != null) map['ice_keepalive_ms'] = iceKeepaliveMs;
    if (hostAcceptanceMinWaitMs != null) map['host_acceptance_min_wait_ms'] = hostAcceptanceMinWaitMs;
    if (srflxAcceptanceMinWaitMs != null) {
      map['srflx_acceptance_min_wait_ms'] = srflxAcceptanceMinWaitMs;
    }
    if (prflxAcceptanceMinWaitMs != null) {
      map['prflx_acceptance_min_wait_ms'] = prflxAcceptanceMinWaitMs;
    }
    if (relayAcceptanceMinWaitMs != null) map['relay_acceptance_min_wait_ms'] = relayAcceptanceMinWaitMs;
    if (dtlsRetransmissionIntervalMs != null) {
      map['dtls_retransmission_interval_ms'] = dtlsRetransmissionIntervalMs;
    }
    if (stunGatherTimeoutMs != null) map['stun_gather_timeout_ms'] = stunGatherTimeoutMs;
    if (multicastDnsHostName != null) map['multicast_dns_host_name'] = multicastDnsHostName;
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
