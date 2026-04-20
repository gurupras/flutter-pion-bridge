package pionserver

import (
	"strings"
	"testing"

	"github.com/pion/webrtc/v4"
)

// --- applySettingsEngine ---

func TestApplySettingsEngine_Empty(t *testing.T) {
	se := webrtc.SettingEngine{}
	if err := applySettingsEngine(&se, map[string]interface{}{}); err != nil {
		t.Errorf("unexpected error for empty config: %v", err)
	}
}

func TestApplySettingsEngine_BooleanFlags(t *testing.T) {
	tests := []struct {
		key string
	}{
		{"disable_active_tcp"},
		{"disable_certificate_fingerprint_verification"},
		{"disable_close_by_dtls"},
		{"disable_srtcp_replay_protection"},
		{"disable_srtp_replay_protection"},
		{"enable_data_channel_block_write"},
		{"enable_sctp_zero_checksum"},
	}
	for _, tt := range tests {
		t.Run(tt.key, func(t *testing.T) {
			se := webrtc.SettingEngine{}
			err := applySettingsEngine(&se, map[string]interface{}{tt.key: true})
			if err != nil {
				t.Errorf("unexpected error for %q=true: %v", tt.key, err)
			}
		})
	}
}

func TestApplySettingsEngine_NumericSettings(t *testing.T) {
	tests := []struct {
		key   string
		value interface{}
	}{
		{"sctp_max_receive_buffer_size", int(4194304)},
		{"sctp_max_message_size", int(65536)},
		{"sctp_min_cwnd", int(4194304)},
		{"sctp_cwnd_ca_step", int(1048576)},
		{"receive_mtu", int(1400)},
		{"ice_max_binding_requests", int(7)},
		{"dtls_replay_protection_window", int(64)},
		{"srtcp_replay_protection_window", int(64)},
		{"srtp_replay_protection_window", int(64)},
	}
	for _, tt := range tests {
		t.Run(tt.key, func(t *testing.T) {
			se := webrtc.SettingEngine{}
			err := applySettingsEngine(&se, map[string]interface{}{tt.key: tt.value})
			if err != nil {
				t.Errorf("unexpected error for %q: %v", tt.key, err)
			}
		})
	}
}

func TestApplySettingsEngine_NumericFromFloat64(t *testing.T) {
	// msgpack/JSON may decode numbers as float64
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"sctp_max_receive_buffer_size": float64(4194304),
		"receive_mtu":                  float64(1400),
	})
	if err != nil {
		t.Errorf("unexpected error when values are float64: %v", err)
	}
}

func TestApplySettingsEngine_EphemeralUDPPortRange_Both(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"ephemeral_udp_port_min": int(10000),
		"ephemeral_udp_port_max": int(20000),
	})
	if err != nil {
		t.Errorf("unexpected error with both ports: %v", err)
	}
}

func TestApplySettingsEngine_EphemeralUDPPortRange_OnlyMin(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"ephemeral_udp_port_min": int(10000),
	})
	if err == nil {
		t.Error("expected error when only min is provided")
	}
	if !strings.Contains(err.Error(), "ephemeral_udp_port_min") {
		t.Errorf("error should mention field name, got: %v", err)
	}
}

func TestApplySettingsEngine_EphemeralUDPPortRange_OnlyMax(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"ephemeral_udp_port_max": int(20000),
	})
	if err == nil {
		t.Error("expected error when only max is provided")
	}
}

func TestApplySettingsEngine_ICETimeouts_AllThree(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"ice_disconnected_timeout_ms": int(5000),
		"ice_failed_timeout_ms":       int(25000),
		"ice_keepalive_ms":            int(2000),
	})
	if err != nil {
		t.Errorf("unexpected error with all three ICE timeouts: %v", err)
	}
}

func TestApplySettingsEngine_ICETimeouts_OnlyOne(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"ice_disconnected_timeout_ms": int(5000),
	})
	if err == nil {
		t.Error("expected error when only one ICE timeout is provided")
	}
	if !strings.Contains(err.Error(), "ice_disconnected_timeout_ms") {
		t.Errorf("error should mention field name, got: %v", err)
	}
}

func TestApplySettingsEngine_ICETimeouts_OnlyTwo(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"ice_disconnected_timeout_ms": int(5000),
		"ice_failed_timeout_ms":       int(25000),
	})
	if err == nil {
		t.Error("expected error when keepalive is missing")
	}
}

func TestApplySettingsEngine_DurationSettings(t *testing.T) {
	tests := []string{
		"host_acceptance_min_wait_ms",
		"srflx_acceptance_min_wait_ms",
		"prflx_acceptance_min_wait_ms",
		"relay_acceptance_min_wait_ms",
		"dtls_retransmission_interval_ms",
		"sctp_rto_max_ms",
		"stun_gather_timeout_ms",
	}
	for _, key := range tests {
		t.Run(key, func(t *testing.T) {
			se := webrtc.SettingEngine{}
			err := applySettingsEngine(&se, map[string]interface{}{key: int(500)})
			if err != nil {
				t.Errorf("unexpected error for %q: %v", key, err)
			}
		})
	}
}

func TestApplySettingsEngine_MulticastDNSHostName(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"multicast_dns_host_name": "myhost.local",
	})
	if err != nil {
		t.Errorf("unexpected error for multicast_dns_host_name: %v", err)
	}
}

func TestApplySettingsEngine_UnknownKeysIgnored(t *testing.T) {
	se := webrtc.SettingEngine{}
	err := applySettingsEngine(&se, map[string]interface{}{
		"unknown_setting":     true,
		"another_unknown_key": 12345,
	})
	if err != nil {
		t.Errorf("unknown keys should be silently ignored, got: %v", err)
	}
}

// --- toInt ---

func TestToInt(t *testing.T) {
	cases := []struct {
		input    interface{}
		wantVal  int64
		wantOk   bool
	}{
		{int(42), 42, true},
		{int8(8), 8, true},
		{int16(16), 16, true},
		{int32(32), 32, true},
		{int64(64), 64, true},
		{uint(10), 10, true},
		{uint8(8), 8, true},
		{uint16(16), 16, true},
		{uint32(32), 32, true},
		{uint64(64), 64, true},
		{float32(1.9), 1, true},
		{float64(3.7), 3, true},
		{"not a number", 0, false},
		{nil, 0, false},
		{true, 0, false},
	}
	for _, c := range cases {
		val, ok := toInt(c.input)
		if ok != c.wantOk {
			t.Errorf("toInt(%T=%v): ok=%v, want %v", c.input, c.input, ok, c.wantOk)
		}
		if ok && val != c.wantVal {
			t.Errorf("toInt(%T=%v): val=%v, want %v", c.input, c.input, val, c.wantVal)
		}
	}
}

// --- handleInit with settings_engine ---

func TestHandleInit_WithSettingsEngine(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(&Message{
		Type: "init",
		ID:   1,
		Data: map[string]interface{}{
			"settings_engine": map[string]interface{}{
				"sctp_max_receive_buffer_size": int(2097152),
				"receive_mtu":                  int(1300),
				"disable_active_tcp":           true,
			},
		},
	})

	if resp.Type != "init:ack" {
		t.Errorf("expected init:ack, got %s: %v", resp.Type, resp.Data)
	}
	if resp.Data["version"] != "1.0.0" {
		t.Errorf("expected version 1.0.0, got %v", resp.Data["version"])
	}
}

func TestHandleInit_WithSettingsEngine_InvalidPortRange(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(&Message{
		Type: "init",
		ID:   1,
		Data: map[string]interface{}{
			"settings_engine": map[string]interface{}{
				"ephemeral_udp_port_min": int(10000),
				// max intentionally omitted
			},
		},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

func TestHandleInit_WithSettingsEngine_InvalidICETimeouts(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(&Message{
		Type: "init",
		ID:   1,
		Data: map[string]interface{}{
			"settings_engine": map[string]interface{}{
				"ice_disconnected_timeout_ms": int(5000),
				// failed and keepalive intentionally omitted
			},
		},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

func TestHandleInit_RebuildAPI_PCCreateStillWorks(t *testing.T) {
	th := newTestHarness()

	// Init with valid settings
	initResp := th.handler.HandleMessage(&Message{
		Type: "init",
		ID:   1,
		Data: map[string]interface{}{
			"settings_engine": map[string]interface{}{
				"receive_mtu": int(1400),
			},
		},
	})
	if initResp.Type != "init:ack" {
		t.Fatalf("expected init:ack, got %s: %v", initResp.Type, initResp.Data)
	}

	// PC creation should work with the new API
	pcHandle := th.createPC(t)
	if len(pcHandle) != 32 {
		t.Errorf("expected 32-char handle, got %q", pcHandle)
	}
}

func TestHandleInit_DefaultAPI_PCCreateWorksWithoutInit(t *testing.T) {
	// Verify that pc:create works without ever calling init (uses default API)
	th := newTestHarness()
	pcHandle := th.createPC(t)
	if len(pcHandle) != 32 {
		t.Errorf("expected 32-char handle, got %q", pcHandle)
	}
}
