package pionserver

import (
	"strings"
	"testing"
	"time"

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
		input   interface{}
		wantVal int64
		wantOk  bool
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

// ice_renomination reaches pion: its own check refuses a zero interval, which
// it only sees when the key is applied. Without ice_renomination the interval
// is ignored.
func TestApplySettingsEngine_ICERenomination(t *testing.T) {
	se := webrtc.SettingEngine{}
	if err := applySettingsEngine(&se, map[string]interface{}{"ice_renomination": true}); err != nil {
		t.Fatalf("ice_renomination=true: %v", err)
	}
	se = webrtc.SettingEngine{}
	if err := applySettingsEngine(&se, map[string]interface{}{"ice_renomination": true, "ice_renomination_interval_ms": 2000}); err != nil {
		t.Fatalf("with an interval: %v", err)
	}
	se = webrtc.SettingEngine{}
	if err := applySettingsEngine(&se, map[string]interface{}{"ice_renomination": true, "ice_renomination_interval_ms": 0}); err == nil {
		t.Fatal("a zero interval was accepted: the key did not reach pion")
	}
	se = webrtc.SettingEngine{}
	if err := applySettingsEngine(&se, map[string]interface{}{"ice_renomination_interval_ms": 0}); err != nil {
		t.Fatalf("an interval without ice_renomination should be ignored: %v", err)
	}
}

// renominationSettings is the loopback test payload plus these keys: a
// pc:create settings_engine replaces init's, it is not merged with it.
func renominationSettings(extra map[string]interface{}) map[string]interface{} {
	se := loopbackSettingsEngine()
	for k, v := range extra {
		se[k] = v
	}
	return se
}

// pion advertises a=ice-options:renomination exactly when the SettingEngine
// has renomination enabled (the same flag that hands the ICE agent its
// renomination options), so the offer shows whether the key took effect.
// Renomination stays off unless ice_renomination is the bool true.
func TestICERenomination_OffUnlessEnabled(t *testing.T) {
	cases := []struct {
		name string
		se   map[string]interface{} // pc:create settings_engine; nil keeps init's
		want bool
	}{
		{"no settings_engine", nil, false},
		{"loopback only", renominationSettings(nil), false},
		{"false", renominationSettings(map[string]interface{}{"ice_renomination": false}), false},
		{"interval without the flag", renominationSettings(map[string]interface{}{"ice_renomination_interval_ms": 2000}), false},
		{"not a bool", renominationSettings(map[string]interface{}{"ice_renomination": "true"}), false},
		{"true", renominationSettings(map[string]interface{}{"ice_renomination": true}), true},
		{"true with an interval", renominationSettings(map[string]interface{}{"ice_renomination": true, "ice_renomination_interval_ms": 2000}), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			th := newTestHarness()
			th.pcSettings = []map[string]interface{}{c.se}
			pc := th.createPC(t)
			if resp := th.handler.HandleMessage(&Message{
				Type: "pc:createDc", ID: 2, Handle: pc,
				Data: map[string]interface{}{"label": "test", "options": map[string]interface{}{}},
			}); resp.Type != "pc:createDc:ack" {
				t.Fatalf("expected pc:createDc:ack, got %s: %v", resp.Type, resp.Data)
			}
			resp := th.handler.HandleMessage(&Message{Type: "pc:offer", ID: 3, Handle: pc, Data: map[string]interface{}{}})
			if resp.Type != "pc:offer:ack" {
				t.Fatalf("expected pc:offer:ack, got %s: %v", resp.Type, resp.Data)
			}
			sdp, _ := resp.Data["sdp"].(string)
			if got := strings.Contains(sdp, "renomination"); got != c.want {
				t.Errorf("offer advertises renomination = %v, want %v:\n%s", got, c.want, sdp)
			}
		})
	}
}

// The same applies to init's settings_engine, which every pc:create without
// its own inherits.
func TestICERenomination_FromInit(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(&Message{
		Type: "init", ID: 1,
		Data: map[string]interface{}{"settings_engine": renominationSettings(map[string]interface{}{"ice_renomination": true})},
	})
	if resp.Type != "init:ack" {
		t.Fatalf("expected init:ack, got %s: %v", resp.Type, resp.Data)
	}
	pc := th.createPC(t)
	th.handler.HandleMessage(&Message{
		Type: "pc:createDc", ID: 2, Handle: pc,
		Data: map[string]interface{}{"label": "test", "options": map[string]interface{}{}},
	})
	offer := th.handler.HandleMessage(&Message{Type: "pc:offer", ID: 3, Handle: pc, Data: map[string]interface{}{}})
	if sdp, _ := offer.Data["sdp"].(string); !strings.Contains(sdp, "renomination") {
		t.Errorf("init's ice_renomination did not reach pc:create's offer:\n%s", sdp)
	}
}

// A bad interval fails init with INVALID_REQUEST and names the key.
func TestHandleInit_ICERenominationZeroInterval(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(&Message{
		Type: "init", ID: 1,
		Data: map[string]interface{}{"settings_engine": map[string]interface{}{
			"ice_renomination": true, "ice_renomination_interval_ms": -1,
		}},
	})
	if resp.Type != "error" || resp.Data["code"] != "INVALID_REQUEST" {
		t.Fatalf("expected INVALID_REQUEST, got %s: %v", resp.Type, resp.Data)
	}
	if msg, _ := resp.Data["message"].(string); !strings.Contains(msg, "ice_renomination_interval_ms") {
		t.Errorf("error does not name the key: %v", resp.Data)
	}
}

// Peers connect with renomination on either side or both. The offerer is the
// controlling agent, the only one that renominates.
func TestICERenomination_Connects(t *testing.T) {
	on := renominationSettings(map[string]interface{}{"ice_renomination": true, "ice_renomination_interval_ms": 500})
	cases := []struct {
		name              string
		offerer, answerer map[string]interface{}
	}{
		{"both", on, on},
		{"controlling only", on, nil},
		{"controlled only", nil, on},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			th := newTestHarness()
			th.pcSettings = []map[string]interface{}{c.offerer, c.answerer}
			offerer, answerer, dc := th.createConnectedPCPair(t)
			for handle, se := range map[string]map[string]interface{}{offerer: c.offerer, answerer: c.answerer} {
				res, _ := th.registry.Lookup(handle)
				sdp := res.(*webrtc.PeerConnection).LocalDescription().SDP
				if strings.Contains(sdp, "renomination") != (se != nil) {
					t.Fatalf("%s: renomination advertised = %v, want %v", handle, se == nil, se != nil)
				}
			}
			// Stay up past several renomination intervals: a renomination
			// that broke the selected pair would show here.
			time.Sleep(2 * time.Second)
			const text = "after renomination checks"
			th.handler.HandleMessage(&Message{
				Type: "dc:send", ID: 20, Handle: dc,
				Data: map[string]interface{}{"data": text, "is_binary": false},
			})
			deadline := time.Now().Add(5 * time.Second)
			for {
				delivered := false
				for _, e := range th.getEvents() {
					if e.Type == "event:connectionStateChange" && (e.Handle == offerer || e.Handle == answerer) {
						if s, _ := e.Data["state"].(string); s == "failed" || s == "disconnected" {
							t.Fatalf("%s went %s", e.Handle, s)
						}
					}
					if e.Type == "event:dataChannelMessage" && e.Handle != dc && e.Data["data"] == text {
						delivered = true
					}
				}
				if delivered {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("the answerer did not receive the message")
				}
				time.Sleep(20 * time.Millisecond)
			}
		})
	}
}
