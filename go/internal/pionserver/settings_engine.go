package pionserver

import (
	"fmt"
	"time"

	"github.com/pion/webrtc/v4"
)

// applySettingsEngine applies serializable settings from a decoded config map to
// a SettingEngine. Only scalar, non-callback settings are supported; function-typed
// settings (SetInterfaceFilter, SetIPFilter, SetVNet, etc.) cannot cross the wire.
//
// Supported keys:
//
//	Boolean flags:
//	  disable_active_tcp
//	  disable_certificate_fingerprint_verification
//	  disable_close_by_dtls
//	  disable_srtcp_replay_protection
//	  disable_srtp_replay_protection
//	  enable_data_channel_block_write
//	  enable_sctp_zero_checksum
//
//	Numeric:
//	  sctp_max_receive_buffer_size (int) → SetSCTPMaxReceiveBufferSize
//	  sctp_max_message_size (int)        → SetSCTPMaxMessageSize
//	  receive_mtu (int)                  → SetReceiveMTU
//	  ice_max_binding_requests (int)     → SetICEMaxBindingRequests
//	  dtls_replay_protection_window (int)  → SetDTLSReplayProtectionWindow
//	  srtcp_replay_protection_window (int) → SetSRTCPReplayProtectionWindow
//	  srtp_replay_protection_window (int)  → SetSRTPReplayProtectionWindow
//	  ephemeral_udp_port_min + ephemeral_udp_port_max → SetEphemeralUDPPortRange (both required)
//
//	Durations (milliseconds):
//	  ice_disconnected_timeout_ms + ice_failed_timeout_ms + ice_keepalive_ms → SetICETimeouts (all three required)
//	  host_acceptance_min_wait_ms   → SetHostAcceptanceMinWait
//	  srflx_acceptance_min_wait_ms  → SetSrflxAcceptanceMinWait
//	  prflx_acceptance_min_wait_ms  → SetPrflxAcceptanceMinWait
//	  relay_acceptance_min_wait_ms  → SetRelayAcceptanceMinWait
//	  dtls_retransmission_interval_ms → SetDTLSRetransmissionInterval
//	  stun_gather_timeout_ms        → SetSTUNGatherTimeout
//
//	String:
//	  multicast_dns_host_name → SetMulticastDNSHostName
func applySettingsEngine(se *webrtc.SettingEngine, cfg map[string]interface{}) error {
	// --- Boolean flags ---
	if v, ok := cfg["disable_active_tcp"].(bool); ok {
		se.DisableActiveTCP(v)
	}
	if v, ok := cfg["disable_certificate_fingerprint_verification"].(bool); ok {
		se.DisableCertificateFingerprintVerification(v)
	}
	if v, ok := cfg["disable_close_by_dtls"].(bool); ok {
		se.DisableCloseByDTLS(v)
	}
	if v, ok := cfg["disable_srtcp_replay_protection"].(bool); ok {
		se.DisableSRTCPReplayProtection(v)
	}
	if v, ok := cfg["disable_srtp_replay_protection"].(bool); ok {
		se.DisableSRTPReplayProtection(v)
	}
	if v, ok := cfg["enable_data_channel_block_write"].(bool); ok {
		se.EnableDataChannelBlockWrite(v)
	}
	if v, ok := cfg["enable_sctp_zero_checksum"].(bool); ok {
		se.EnableSCTPZeroChecksum(v)
	}

	// --- Numeric settings ---
	if v, ok := toInt(cfg["sctp_max_receive_buffer_size"]); ok {
		se.SetSCTPMaxReceiveBufferSize(uint32(v))
	}
	if v, ok := toInt(cfg["sctp_max_message_size"]); ok {
		se.SetSCTPMaxMessageSize(uint32(v))
	}
	if v, ok := toInt(cfg["receive_mtu"]); ok {
		se.SetReceiveMTU(uint(v))
	}
	if v, ok := toInt(cfg["ice_max_binding_requests"]); ok {
		se.SetICEMaxBindingRequests(uint16(v))
	}
	if v, ok := toInt(cfg["dtls_replay_protection_window"]); ok {
		se.SetDTLSReplayProtectionWindow(uint(v))
	}
	if v, ok := toInt(cfg["srtcp_replay_protection_window"]); ok {
		se.SetSRTCPReplayProtectionWindow(uint(v))
	}
	if v, ok := toInt(cfg["srtp_replay_protection_window"]); ok {
		se.SetSRTPReplayProtectionWindow(uint(v))
	}

	// SetEphemeralUDPPortRange requires both min and max together.
	portMin, hasMin := toInt(cfg["ephemeral_udp_port_min"])
	portMax, hasMax := toInt(cfg["ephemeral_udp_port_max"])
	switch {
	case hasMin && hasMax:
		if err := se.SetEphemeralUDPPortRange(uint16(portMin), uint16(portMax)); err != nil {
			return fmt.Errorf("invalid ephemeral UDP port range [%d, %d]: %w", portMin, portMax, err)
		}
	case hasMin || hasMax:
		return fmt.Errorf("ephemeral_udp_port_min and ephemeral_udp_port_max must be provided together")
	}

	// --- Duration settings (milliseconds) ---

	// SetICETimeouts requires all three values together.
	discMs, hasDisc := toInt(cfg["ice_disconnected_timeout_ms"])
	failMs, hasFail := toInt(cfg["ice_failed_timeout_ms"])
	keepMs, hasKeep := toInt(cfg["ice_keepalive_ms"])
	switch {
	case hasDisc && hasFail && hasKeep:
		se.SetICETimeouts(
			time.Duration(discMs)*time.Millisecond,
			time.Duration(failMs)*time.Millisecond,
			time.Duration(keepMs)*time.Millisecond,
		)
	case hasDisc || hasFail || hasKeep:
		return fmt.Errorf("ice_disconnected_timeout_ms, ice_failed_timeout_ms, and ice_keepalive_ms must all be provided together")
	}

	if v, ok := toInt(cfg["host_acceptance_min_wait_ms"]); ok {
		se.SetHostAcceptanceMinWait(time.Duration(v) * time.Millisecond)
	}
	if v, ok := toInt(cfg["srflx_acceptance_min_wait_ms"]); ok {
		se.SetSrflxAcceptanceMinWait(time.Duration(v) * time.Millisecond)
	}
	if v, ok := toInt(cfg["prflx_acceptance_min_wait_ms"]); ok {
		se.SetPrflxAcceptanceMinWait(time.Duration(v) * time.Millisecond)
	}
	if v, ok := toInt(cfg["relay_acceptance_min_wait_ms"]); ok {
		se.SetRelayAcceptanceMinWait(time.Duration(v) * time.Millisecond)
	}
	if v, ok := toInt(cfg["dtls_retransmission_interval_ms"]); ok {
		se.SetDTLSRetransmissionInterval(time.Duration(v) * time.Millisecond)
	}
	if v, ok := toInt(cfg["stun_gather_timeout_ms"]); ok {
		se.SetSTUNGatherTimeout(time.Duration(v) * time.Millisecond)
	}

	// --- String settings ---
	if v, ok := cfg["multicast_dns_host_name"].(string); ok && v != "" {
		se.SetMulticastDNSHostName(v)
	}

	return nil
}

// toInt converts any numeric value (as decoded from msgpack) to int64.
func toInt(v interface{}) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int8:
		return int64(n), true
	case int16:
		return int64(n), true
	case int32:
		return int64(n), true
	case int64:
		return n, true
	case uint:
		return int64(n), true
	case uint8:
		return int64(n), true
	case uint16:
		return int64(n), true
	case uint32:
		return int64(n), true
	case uint64:
		return int64(n), true
	case float32:
		return int64(n), true
	case float64:
		return int64(n), true
	default:
		return 0, false
	}
}
