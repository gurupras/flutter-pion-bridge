package pionserver

import (
	"bytes"
	"testing"
)

// connectDetachedPair negotiates two sessions whose settings detach data
// channels, and returns the clients with an open channel on each side.
func connectDetachedPair(t *testing.T, extra map[string]interface{}) (a, b *testFrameClient, dcA, dcB string) {
	t.Helper()
	s := NewServer(NewRegistry(), "")
	a = newTestFrameClient(t, s)
	b = newTestFrameClient(t, s)
	se := loopbackSettingsEngine()
	se["detach_data_channels"] = true
	for k, v := range extra {
		se[k] = v
	}
	a.request("init", "", map[string]interface{}{"settings_engine": se})
	b.request("init", "", map[string]interface{}{"settings_engine": se})

	pcA := a.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	pcB := b.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	dcA = a.request("pc:createDc", pcA, map[string]interface{}{"label": "bulk", "options": map[string]interface{}{"ordered": true}}).Data["dc_handle"].(string)

	gather := func(c *testFrameClient) (out []map[string]interface{}) {
		c.waitEvent("event:iceGatheringComplete", func(m Message) {
			if m.Type == "event:iceCandidate" {
				out = append(out, m.Data)
			}
		})
		return
	}
	offer := a.request("pc:offer", pcA, map[string]interface{}{}).Data["sdp"].(string)
	a.request("pc:setLocalDesc", pcA, map[string]interface{}{"sdp": offer, "type": "offer"})
	candsA := gather(a)
	b.request("pc:setRemoteDesc", pcB, map[string]interface{}{"sdp": offer, "type": "offer"})
	answer := b.request("pc:answer", pcB, map[string]interface{}{}).Data["sdp"].(string)
	b.request("pc:setLocalDesc", pcB, map[string]interface{}{"sdp": answer, "type": "answer"})
	candsB := gather(b)
	a.request("pc:setRemoteDesc", pcA, map[string]interface{}{"sdp": answer, "type": "answer"})
	for _, c := range candsA {
		b.request("pc:addIce", pcB, c)
	}
	for _, c := range candsB {
		a.request("pc:addIce", pcA, c)
	}

	a.waitEvent("event:dataChannelOpen", nil)
	dcB = b.waitEvent("event:dataChannel", nil).Data["dc_handle"].(string)
	if m := b.waitEvent("event:dataChannelOpen", nil); m.Handle != dcB {
		t.Fatalf("open event for %s, want %s", m.Handle, dcB)
	}
	return a, b, dcA, dcB
}

func waitMessage(t *testing.T, c *testFrameClient) Message {
	t.Helper()
	return c.waitEvent("event:dataChannelMessage", nil)
}

// Detached channels (created and remote) carry text and binary both ways,
// including a message larger than the initial read buffer.
func TestDetached_MessagesBothWays(t *testing.T) {
	a, b, dcA, dcB := connectDetachedPair(t, nil)

	a.request("dc:send", dcA, map[string]interface{}{"data": "hello detached"})
	if m := waitMessage(t, b); m.Data["data"] != "hello detached" || m.Data["is_binary"] != false || m.Handle != dcB {
		t.Fatalf("text: %v", m.Data)
	}

	big := bytes.Repeat([]byte{0xAB, 0xCD, 0xEF}, 400_000) // 1.2 MB, > default 64 KB buffer
	cfgBig := big[:1<<20]
	a.request("dc:send", dcA, map[string]interface{}{"data": cfgBig})
	m := waitMessage(t, b)
	got, _ := m.Data["data"].([]byte)
	if !bytes.Equal(got, cfgBig) || m.Data["is_binary"] != true {
		t.Fatalf("binary: got %d bytes, want %d", len(got), len(cfgBig))
	}

	b.request("dc:send", dcB, map[string]interface{}{"data": []byte("reply")})
	if m := waitMessage(t, a); string(m.Data["data"].([]byte)) != "reply" {
		t.Fatalf("reply: %v", m.Data)
	}
}

// With block writes, a burst of back-to-back sends is delivered complete and
// in order (each write waits for SCTP buffer space instead of queueing in pion).
func TestDetached_BlockWriteBurstInOrder(t *testing.T) {
	a, b, dcA, _ := connectDetachedPair(t, map[string]interface{}{
		"enable_data_channel_block_write": true,
		"sctp_max_receive_buffer_size":    8 << 20,
		"sctp_max_message_size":           1 << 20,
	})
	const n = 60                    // 60 x 64 KB: enough to fill and drain the send buffer repeatedly,
	payload := make([]byte, 64<<10) // small enough to stay well inside the ack timeout under -race
	for i := 0; i < n; i++ {
		p := append([]byte{byte(i)}, payload...)
		a.request("dc:send", dcA, map[string]interface{}{"data": p, "await_drain": false})
	}
	for i := 0; i < n; i++ {
		got, _ := waitMessage(t, b).Data["data"].([]byte)
		if len(got) != len(payload)+1 || got[0] != byte(i) {
			t.Fatalf("message %d: len %d first byte %d", i, len(got), got[0])
		}
	}
}

// Closing a detached channel still produces close events on both sides.
func TestDetached_CloseEvents(t *testing.T) {
	a, b, dcA, dcB := connectDetachedPair(t, nil)
	a.request("dc:close", dcA, map[string]interface{}{})
	if m := a.waitEvent("event:dataChannelClose", nil); m.Handle != dcA {
		t.Fatalf("local close for %s", m.Handle)
	}
	if m := b.waitEvent("event:dataChannelClose", nil); m.Handle != dcB {
		t.Fatalf("remote close for %s", m.Handle)
	}
}

// A send before the detached channel opens fails cleanly instead of panicking.
func TestDetached_SendBeforeOpenFails(t *testing.T) {
	s := NewServer(NewRegistry(), "")
	a := newTestFrameClient(t, s)
	se := loopbackSettingsEngine()
	se["detach_data_channels"] = true
	a.request("init", "", map[string]interface{}{"settings_engine": se})
	pc := a.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	dc := a.request("pc:createDc", pc, map[string]interface{}{"label": "x"}).Data["dc_handle"].(string)

	frame := Message{Type: "dc:send", ID: 99, Handle: dc, Data: map[string]interface{}{"data": []byte("early")}}
	resp := a.requestRaw(frame)
	if resp.Type != "error" || resp.Data["code"] != "DC_SEND_ERROR" {
		t.Fatalf("expected DC_SEND_ERROR, got %s %v", resp.Type, resp.Data)
	}
}

// pion applies a SettingEngine per API, so one session can hold several: a
// pc:create may carry its own settings_engine, e.g. a detached connection for
// bulk transfer alongside an attached one for latency-sensitive traffic.
func TestPerPeerConnectionSettings(t *testing.T) {
	th := newTestHarness()
	detached := loopbackSettingsEngine()
	detached["detach_data_channels"] = true

	create := func(cfg map[string]interface{}) string {
		data := map[string]interface{}{}
		if cfg != nil {
			data["settings_engine"] = cfg
		}
		resp := th.handler.HandleMessage(&Message{Type: "pc:create", ID: 1, Data: data})
		if resp.Type != "pc:create:ack" {
			t.Fatalf("pc:create: %s %v", resp.Type, resp.Data)
		}
		return resp.Data["handle"].(string)
	}

	bulk := create(detached)
	input := create(nil) // session default: attached
	if p := th.handler.pcProfile(bulk); !p.detach {
		t.Error("bulk PeerConnection should detach its data channels")
	}
	if p := th.handler.pcProfile(input); p.detach {
		t.Error("input PeerConnection should not detach")
	}
	if th.handler.pcProfile(bulk).api == th.handler.pcProfile(input).api {
		t.Error("different settings must use different APIs")
	}

	// The same payload reuses one API rather than piling them up.
	again := create(detached)
	if th.handler.pcProfile(again).api != th.handler.pcProfile(bulk).api {
		t.Error("identical settings should share one API")
	}

	// Each channel follows its own PeerConnection's setting.
	dcOf := func(pc string) string {
		resp := th.handler.HandleMessage(&Message{Type: "pc:createDc", ID: 2, Handle: pc,
			Data: map[string]interface{}{"label": "c"}})
		if resp.Type != "pc:createDc:ack" {
			t.Fatalf("pc:createDc: %s %v", resp.Type, resp.Data)
		}
		return resp.Data["dc_handle"].(string)
	}
	stateOf := func(dc string) *DCSendState {
		s, ok := th.registry.LookupDCSendState(dc)
		if !ok {
			t.Fatalf("no send state for %s", dc)
		}
		return s
	}
	if !stateOf(dcOf(bulk)).detach {
		t.Error("channel on the bulk PeerConnection should be detached")
	}
	if stateOf(dcOf(input)).detach {
		t.Error("channel on the input PeerConnection should not be detached")
	}

	// Closing a PeerConnection forgets its profile (back to the session default).
	th.handler.HandleMessage(&Message{Type: "pc:close", ID: 3, Handle: bulk, Data: map[string]interface{}{}})
	if th.handler.pcProfile(bulk) != th.handler.defaultProfile {
		t.Error("pc:close should forget the per-PC profile")
	}
}
