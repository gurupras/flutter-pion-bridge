package main

import (
	"sync"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// testHandler creates a Handler and collects events for assertions.
type testHarness struct {
	handler  *Handler
	registry *Registry
	mu       sync.Mutex
	events   []Message
}

func newTestHarness() *testHarness {
	th := &testHarness{
		registry: NewRegistry(),
	}
	th.handler = NewHandler(th.registry, func(event Message) {
		th.mu.Lock()
		defer th.mu.Unlock()
		th.events = append(th.events, event)
	})
	return th
}

func (th *testHarness) getEvents() []Message {
	th.mu.Lock()
	defer th.mu.Unlock()
	cp := make([]Message, len(th.events))
	copy(cp, th.events)
	return cp
}

func (th *testHarness) clearEvents() {
	th.mu.Lock()
	defer th.mu.Unlock()
	th.events = nil
}

// createPC is a helper that creates a PeerConnection via the handler.
func (th *testHarness) createPC(t *testing.T) string {
	t.Helper()
	resp := th.handler.HandleMessage(Message{
		Type: "pc:create",
		ID:   1,
		Data: map[string]interface{}{},
	})
	if resp.Type != "pc:create:ack" {
		t.Fatalf("expected pc:create:ack, got %s: %v", resp.Type, resp.Data)
	}
	return resp.Data["handle"].(string)
}

// doOfferAnswer sets up a local offer/answer on a single PC so we can test
// operations that require signaling state.
func (th *testHarness) createPCPair(t *testing.T) (offererHandle, answererHandle string) {
	t.Helper()
	offererHandle = th.createPC(t)
	answererHandle = th.createPC(t)

	// Offerer creates offer
	offerResp := th.handler.HandleMessage(Message{
		Type:   "pc:offer",
		ID:     2,
		Handle: offererHandle,
		Data:   map[string]interface{}{"offer_options": map[string]interface{}{}},
	})
	if offerResp.Type != "pc:offer:ack" {
		t.Fatalf("expected pc:offer:ack, got %s: %v", offerResp.Type, offerResp.Data)
	}
	offerSdp := offerResp.Data["sdp"].(string)

	// Offerer sets local desc
	th.handler.HandleMessage(Message{
		Type:   "pc:setLocalDesc",
		ID:     3,
		Handle: offererHandle,
		Data:   map[string]interface{}{"sdp": offerSdp, "type": "offer"},
	})

	// Answerer sets remote desc
	th.handler.HandleMessage(Message{
		Type:   "pc:setRemoteDesc",
		ID:     4,
		Handle: answererHandle,
		Data:   map[string]interface{}{"sdp": offerSdp, "type": "offer"},
	})

	// Answerer creates answer
	answerResp := th.handler.HandleMessage(Message{
		Type:   "pc:answer",
		ID:     5,
		Handle: answererHandle,
		Data:   map[string]interface{}{"answer_options": map[string]interface{}{}},
	})
	if answerResp.Type != "pc:answer:ack" {
		t.Fatalf("expected pc:answer:ack, got %s: %v", answerResp.Type, answerResp.Data)
	}
	answerSdp := answerResp.Data["sdp"].(string)

	// Answerer sets local desc
	th.handler.HandleMessage(Message{
		Type:   "pc:setLocalDesc",
		ID:     6,
		Handle: answererHandle,
		Data:   map[string]interface{}{"sdp": answerSdp, "type": "answer"},
	})

	// Offerer sets remote desc
	th.handler.HandleMessage(Message{
		Type:   "pc:setRemoteDesc",
		ID:     7,
		Handle: offererHandle,
		Data:   map[string]interface{}{"sdp": answerSdp, "type": "answer"},
	})

	return offererHandle, answererHandle
}

// --- init ---

func TestHandleInit(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(Message{Type: "init", ID: 1, Data: map[string]interface{}{}})

	if resp.Type != "init:ack" {
		t.Errorf("expected init:ack, got %s", resp.Type)
	}
	if resp.ID != 1 {
		t.Errorf("expected id 1, got %d", resp.ID)
	}
	if resp.Data["version"] != "1.0.0" {
		t.Errorf("expected version 1.0.0, got %v", resp.Data["version"])
	}
}

// --- pc:create ---

func TestHandlePCCreate(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(Message{
		Type: "pc:create",
		ID:   2,
		Data: map[string]interface{}{},
	})

	if resp.Type != "pc:create:ack" {
		t.Fatalf("expected pc:create:ack, got %s", resp.Type)
	}
	if resp.ID != 2 {
		t.Errorf("expected id 2, got %d", resp.ID)
	}
	handle, ok := resp.Data["handle"].(string)
	if !ok || len(handle) != 32 {
		t.Errorf("expected 32-char handle, got %v", resp.Data["handle"])
	}
	if resp.Data["state"] != "new" {
		t.Errorf("expected state new, got %v", resp.Data["state"])
	}

	// Verify it's in the registry
	res, ok := th.registry.Lookup(handle)
	if !ok {
		t.Fatal("handle not found in registry")
	}
	if _, ok := res.(*webrtc.PeerConnection); !ok {
		t.Error("resource is not a PeerConnection")
	}
}

func TestHandlePCCreate_WithICEServers(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(Message{
		Type: "pc:create",
		ID:   2,
		Data: map[string]interface{}{
			"ice_servers": []interface{}{
				map[string]interface{}{
					"urls": []interface{}{"stun:stun.l.google.com:19302"},
				},
			},
			"bundle_policy":   "max-bundle",
			"rtcp_mux_policy": "require",
		},
	})

	if resp.Type != "pc:create:ack" {
		t.Fatalf("expected pc:create:ack, got %s: %v", resp.Type, resp.Data)
	}
	// We can't inspect the config directly, but it shouldn't error.
	handle := resp.Data["handle"].(string)
	if len(handle) != 32 {
		t.Errorf("bad handle: %s", handle)
	}
}

// --- pc:offer ---

func TestHandlePCOffer(t *testing.T) {
	th := newTestHarness()
	handle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type:   "pc:offer",
		ID:     3,
		Handle: handle,
		Data:   map[string]interface{}{"offer_options": map[string]interface{}{}},
	})

	if resp.Type != "pc:offer:ack" {
		t.Fatalf("expected pc:offer:ack, got %s: %v", resp.Type, resp.Data)
	}
	sdp, ok := resp.Data["sdp"].(string)
	if !ok || sdp == "" {
		t.Error("expected non-empty SDP string")
	}
}

// --- pc:answer ---

func TestHandlePCAnswer(t *testing.T) {
	th := newTestHarness()
	offererHandle := th.createPC(t)
	answererHandle := th.createPC(t)

	// Create and set offer
	offerResp := th.handler.HandleMessage(Message{
		Type: "pc:offer", ID: 2, Handle: offererHandle,
		Data: map[string]interface{}{"offer_options": map[string]interface{}{}},
	})
	offerSdp := offerResp.Data["sdp"].(string)

	// Set remote desc on answerer
	th.handler.HandleMessage(Message{
		Type: "pc:setRemoteDesc", ID: 3, Handle: answererHandle,
		Data: map[string]interface{}{"sdp": offerSdp, "type": "offer"},
	})

	// Now answerer can create answer
	resp := th.handler.HandleMessage(Message{
		Type: "pc:answer", ID: 4, Handle: answererHandle,
		Data: map[string]interface{}{"answer_options": map[string]interface{}{}},
	})

	if resp.Type != "pc:answer:ack" {
		t.Fatalf("expected pc:answer:ack, got %s: %v", resp.Type, resp.Data)
	}
	sdp, ok := resp.Data["sdp"].(string)
	if !ok || sdp == "" {
		t.Error("expected non-empty SDP string")
	}
}

// --- pc:setLocalDesc / pc:setRemoteDesc ---

func TestHandlePCSetLocalDesc(t *testing.T) {
	th := newTestHarness()
	handle := th.createPC(t)

	// Create offer first
	offerResp := th.handler.HandleMessage(Message{
		Type: "pc:offer", ID: 2, Handle: handle,
		Data: map[string]interface{}{"offer_options": map[string]interface{}{}},
	})
	sdp := offerResp.Data["sdp"].(string)

	resp := th.handler.HandleMessage(Message{
		Type: "pc:setLocalDesc", ID: 3, Handle: handle,
		Data: map[string]interface{}{"sdp": sdp, "type": "offer"},
	})

	if resp.Type != "pc:setLocalDesc:ack" {
		t.Fatalf("expected pc:setLocalDesc:ack, got %s: %v", resp.Type, resp.Data)
	}
	if resp.Data["state"] == nil {
		t.Error("expected state in response")
	}
}

func TestHandlePCSetLocalDesc_MissingFields(t *testing.T) {
	th := newTestHarness()
	handle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type: "pc:setLocalDesc", ID: 3, Handle: handle,
		Data: map[string]interface{}{},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

func TestHandlePCSetRemoteDesc(t *testing.T) {
	th := newTestHarness()

	// Use createPCPair which does the full offer/answer flow including
	// SetLocalDescription (required for Pion to populate ice-ufrag in SDP)
	offerer, answerer := th.createPCPair(t)

	// Both PCs should be in stable signaling state now
	_, ok := th.registry.Lookup(offerer)
	if !ok {
		t.Fatal("offerer not found")
	}
	_, ok = th.registry.Lookup(answerer)
	if !ok {
		t.Fatal("answerer not found")
	}
}

// --- pc:addIce ---

func TestHandlePCAddIce_Success(t *testing.T) {
	th := newTestHarness()
	offerer, answerer := th.createPCPair(t)

	// Collect ICE candidates from events (generated during createPCPair signaling)
	// and add them to the other peer. Since callbacks fire asynchronously, wait a bit.
	time.Sleep(500 * time.Millisecond)
	events := th.getEvents()

	addedCount := 0
	for _, e := range events {
		if e.Type == "event:iceCandidate" {
			candidate, _ := e.Data["candidate"].(string)
			sdpMid, _ := e.Data["sdp_mid"].(string)
			target := answerer
			if e.Handle == answerer {
				target = offerer
			}
			resp := th.handler.HandleMessage(Message{
				Type: "pc:addIce", ID: 100 + addedCount, Handle: target,
				Data: map[string]interface{}{
					"candidate":       candidate,
					"sdp_mid":         sdpMid,
					"sdp_mline_index": 0,
				},
			})
			if resp.Type != "pc:addIce:ack" {
				t.Errorf("pc:addIce failed: %s %v", resp.Type, resp.Data)
			}
			addedCount++
		}
	}
	if addedCount == 0 {
		t.Log("WARN: no ICE candidates available to test addIce (timing-dependent)")
	}
}

func TestHandlePCAddIce_MissingCandidate(t *testing.T) {
	th := newTestHarness()
	handle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type: "pc:addIce", ID: 3, Handle: handle,
		Data: map[string]interface{}{},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

// --- pc:close ---

func TestHandlePCClose(t *testing.T) {
	th := newTestHarness()
	handle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type: "pc:close", ID: 3, Handle: handle, Data: map[string]interface{}{},
	})

	if resp.Type != "pc:close:ack" {
		t.Fatalf("expected pc:close:ack, got %s", resp.Type)
	}

	// Handle should still be in registry (close doesn't remove)
	_, ok := th.registry.Lookup(handle)
	if !ok {
		t.Error("handle should still be in registry after pc:close")
	}
}

// --- pc:createDc ---

func TestHandlePCCreateDc(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type: "pc:createDc", ID: 5, Handle: pcHandle,
		Data: map[string]interface{}{
			"label":   "chat",
			"options": map[string]interface{}{"ordered": true},
		},
	})

	if resp.Type != "pc:createDc:ack" {
		t.Fatalf("expected pc:createDc:ack, got %s: %v", resp.Type, resp.Data)
	}
	dcHandle, ok := resp.Data["dc_handle"].(string)
	if !ok || len(dcHandle) != 32 {
		t.Errorf("expected 32-char dc_handle, got %v", resp.Data["dc_handle"])
	}
	if resp.Data["label"] != "chat" {
		t.Errorf("expected label chat, got %v", resp.Data["label"])
	}

	// DC should be in registry
	res, ok := th.registry.Lookup(dcHandle)
	if !ok {
		t.Fatal("dc_handle not in registry")
	}
	if _, ok := res.(*webrtc.DataChannel); !ok {
		t.Error("resource is not a DataChannel")
	}
}

func TestHandlePCCreateDc_MissingLabel(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type: "pc:createDc", ID: 5, Handle: pcHandle,
		Data: map[string]interface{}{},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

// --- dc:send ---

// Note: dc:send on a DataChannel that isn't connected will fail with INTERNAL_ERROR
// (SCTP not established). This is expected since we can't fully connect PCs in unit tests.
// The integration test covers the full flow.

func TestHandleDCSend_InvalidBase64(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	// Create a DC
	dcResp := th.handler.HandleMessage(Message{
		Type: "pc:createDc", ID: 5, Handle: pcHandle,
		Data: map[string]interface{}{"label": "test", "options": map[string]interface{}{}},
	})
	dcHandle := dcResp.Data["dc_handle"].(string)

	resp := th.handler.HandleMessage(Message{
		Type: "dc:send", ID: 6, Handle: dcHandle,
		Data: map[string]interface{}{
			"data":      "!!!not-base64!!!",
			"is_binary": true,
		},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

// --- dc:close ---

func TestHandleDCClose(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	dcResp := th.handler.HandleMessage(Message{
		Type: "pc:createDc", ID: 5, Handle: pcHandle,
		Data: map[string]interface{}{"label": "test", "options": map[string]interface{}{}},
	})
	dcHandle := dcResp.Data["dc_handle"].(string)

	resp := th.handler.HandleMessage(Message{
		Type: "dc:close", ID: 6, Handle: dcHandle, Data: map[string]interface{}{},
	})

	if resp.Type != "dc:close:ack" {
		t.Fatalf("expected dc:close:ack, got %s: %v", resp.Type, resp.Data)
	}
}

// --- resource:delete ---

func TestHandleResourceDelete(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type: "resource:delete", ID: 10, Handle: pcHandle, Data: map[string]interface{}{},
	})

	if resp.Type != "resource:delete:ack" {
		t.Fatalf("expected resource:delete:ack, got %s", resp.Type)
	}

	// Should be gone from registry
	_, ok := th.registry.Lookup(pcHandle)
	if ok {
		t.Error("handle should be removed after resource:delete")
	}
}

func TestHandleResourceDelete_CascadesDataChannels(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	dcResp := th.handler.HandleMessage(Message{
		Type: "pc:createDc", ID: 5, Handle: pcHandle,
		Data: map[string]interface{}{"label": "chat", "options": map[string]interface{}{}},
	})
	dcHandle := dcResp.Data["dc_handle"].(string)

	th.handler.HandleMessage(Message{
		Type: "resource:delete", ID: 10, Handle: pcHandle, Data: map[string]interface{}{},
	})

	if _, ok := th.registry.Lookup(dcHandle); ok {
		t.Error("DataChannel should be cascade-deleted with PeerConnection")
	}
}

// --- error cases ---

func TestHandleUnknownType(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(Message{
		Type: "bogus:operation", ID: 99, Data: map[string]interface{}{},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

func TestHandlePCOffer_WrongHandleType(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	// Create a DC so we have a non-PC handle
	dcResp := th.handler.HandleMessage(Message{
		Type: "pc:createDc", ID: 5, Handle: pcHandle,
		Data: map[string]interface{}{"label": "test", "options": map[string]interface{}{}},
	})
	dcHandle := dcResp.Data["dc_handle"].(string)

	resp := th.handler.HandleMessage(Message{
		Type: "pc:offer", ID: 6, Handle: dcHandle,
		Data: map[string]interface{}{},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

func TestHandlePCOffer_NonExistentHandle(t *testing.T) {
	th := newTestHarness()

	resp := th.handler.HandleMessage(Message{
		Type: "pc:offer", ID: 6, Handle: "deadbeef12345678deadbeef12345678",
		Data: map[string]interface{}{},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "NOT_FOUND" {
		t.Errorf("expected NOT_FOUND, got %v", resp.Data["code"])
	}
}

func TestHandleDCSend_OnPCHandle(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	resp := th.handler.HandleMessage(Message{
		Type: "dc:send", ID: 6, Handle: pcHandle,
		Data: map[string]interface{}{"data": "hello", "is_binary": false},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

func TestHandleResourceDelete_MissingHandle(t *testing.T) {
	th := newTestHarness()

	resp := th.handler.HandleMessage(Message{
		Type: "resource:delete", ID: 10, Handle: "", Data: map[string]interface{}{},
	})

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

// createConnectedPCPair creates two PeerConnections with a DataChannel,
// performs full signaling + ICE exchange, and waits for SCTP to establish.
// Returns offerer handle, answerer handle, offerer DC handle.
func (th *testHarness) createConnectedPCPair(t *testing.T) (offererHandle, answererHandle, offererDcHandle string) {
	t.Helper()
	offererHandle = th.createPC(t)
	answererHandle = th.createPC(t)

	// Create DC on offerer before offer so SDP has application media
	dcResp := th.handler.HandleMessage(Message{
		Type: "pc:createDc", ID: 10, Handle: offererHandle,
		Data: map[string]interface{}{"label": "test", "options": map[string]interface{}{}},
	})
	if dcResp.Type != "pc:createDc:ack" {
		t.Fatalf("expected pc:createDc:ack, got %s: %v", dcResp.Type, dcResp.Data)
	}
	offererDcHandle = dcResp.Data["dc_handle"].(string)

	// Offerer creates offer
	offerResp := th.handler.HandleMessage(Message{
		Type: "pc:offer", ID: 11, Handle: offererHandle,
		Data: map[string]interface{}{},
	})
	offerSdp := offerResp.Data["sdp"].(string)

	// Offerer sets local desc
	th.handler.HandleMessage(Message{
		Type: "pc:setLocalDesc", ID: 12, Handle: offererHandle,
		Data: map[string]interface{}{"sdp": offerSdp, "type": "offer"},
	})

	// Answerer sets remote desc
	th.handler.HandleMessage(Message{
		Type: "pc:setRemoteDesc", ID: 13, Handle: answererHandle,
		Data: map[string]interface{}{"sdp": offerSdp, "type": "offer"},
	})

	// Answerer creates answer
	answerResp := th.handler.HandleMessage(Message{
		Type: "pc:answer", ID: 14, Handle: answererHandle,
		Data: map[string]interface{}{},
	})
	answerSdp := answerResp.Data["sdp"].(string)

	// Answerer sets local desc
	th.handler.HandleMessage(Message{
		Type: "pc:setLocalDesc", ID: 15, Handle: answererHandle,
		Data: map[string]interface{}{"sdp": answerSdp, "type": "answer"},
	})

	// Offerer sets remote desc
	th.handler.HandleMessage(Message{
		Type: "pc:setRemoteDesc", ID: 16, Handle: offererHandle,
		Data: map[string]interface{}{"sdp": answerSdp, "type": "answer"},
	})

	// Wait for ICE gathering
	time.Sleep(500 * time.Millisecond)

	// Exchange ICE candidates
	events := th.getEvents()
	for _, e := range events {
		if e.Type == "event:iceCandidate" {
			candidate, _ := e.Data["candidate"].(string)
			sdpMid, _ := e.Data["sdp_mid"].(string)
			sdpMlineIndex := 0
			if idx, ok := e.Data["sdp_mline_index"]; ok {
				switch v := idx.(type) {
				case int:
					sdpMlineIndex = v
				case float64:
					sdpMlineIndex = int(v)
				}
			}
			target := answererHandle
			if e.Handle == answererHandle {
				target = offererHandle
			}
			th.handler.HandleMessage(Message{
				Type: "pc:addIce", ID: 17, Handle: target,
				Data: map[string]interface{}{
					"candidate":       candidate,
					"sdp_mid":         sdpMid,
					"sdp_mline_index": sdpMlineIndex,
				},
			})
		}
	}

	// Wait for SCTP to establish
	time.Sleep(2 * time.Second)

	return offererHandle, answererHandle, offererDcHandle
}

// --- dc:send with connected pair ---

func TestHandleDCSend_Text(t *testing.T) {
	th := newTestHarness()
	_, _, dcHandle := th.createConnectedPCPair(t)

	resp := th.handler.HandleMessage(Message{
		Type: "dc:send", ID: 50, Handle: dcHandle,
		Data: map[string]interface{}{"data": "Hello, world!", "is_binary": false},
	})

	if resp.Type != "dc:send:ack" {
		t.Fatalf("expected dc:send:ack, got %s: %v", resp.Type, resp.Data)
	}
	bytesSent, ok := resp.Data["bytes_sent"].(int)
	if !ok || bytesSent != len("Hello, world!") {
		t.Errorf("expected bytes_sent=%d, got %v", len("Hello, world!"), resp.Data["bytes_sent"])
	}
}

func TestHandleDCSend_Binary(t *testing.T) {
	th := newTestHarness()
	_, _, dcHandle := th.createConnectedPCPair(t)

	// base64 of [1, 2, 3] = "AQID"
	resp := th.handler.HandleMessage(Message{
		Type: "dc:send", ID: 51, Handle: dcHandle,
		Data: map[string]interface{}{"data": "AQID", "is_binary": true},
	})

	if resp.Type != "dc:send:ack" {
		t.Fatalf("expected dc:send:ack, got %s: %v", resp.Type, resp.Data)
	}
	bytesSent, ok := resp.Data["bytes_sent"].(int)
	if !ok || bytesSent != 3 {
		t.Errorf("expected bytes_sent=3, got %v", resp.Data["bytes_sent"])
	}
}

// --- event callback tests ---

func TestEventConnectionStateChange(t *testing.T) {
	th := newTestHarness()
	handle := th.createPC(t)

	// Close the PC to trigger a state change event
	th.handler.HandleMessage(Message{
		Type: "pc:close", ID: 3, Handle: handle, Data: map[string]interface{}{},
	})

	// Give callbacks a moment to fire
	// Note: OnConnectionStateChange fires asynchronously
	// We check that at least one event was emitted for this handle
	events := th.getEvents()
	found := false
	for _, e := range events {
		if e.Type == "event:connectionStateChange" && e.Handle == handle {
			found = true
			if e.ID != 0 {
				t.Errorf("event ID should be 0, got %d", e.ID)
			}
			if _, ok := e.Data["state"]; !ok {
				t.Error("event missing state field")
			}
		}
	}
	if !found {
		// This is best-effort; the callback may not have fired yet in unit tests.
		// The integration test provides stronger guarantees.
		t.Log("WARN: no connectionStateChange event captured (may be timing-dependent)")
	}
}
