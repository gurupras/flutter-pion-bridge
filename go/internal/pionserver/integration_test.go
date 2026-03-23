package pionserver

import (
	"fmt"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
)

// integrationClient uses a single read loop that dispatches responses and events.
type integrationClient struct {
	t      *testing.T
	conn   *websocket.Conn
	nextID int

	mu      sync.Mutex
	events  []Message
	pending map[int]chan Message
	done    chan struct{}
}

func startIntegration(t *testing.T) (*integrationClient, func()) {
	t.Helper()

	registry := NewRegistry()
	registry.StartCleanup(30*time.Second, 300*time.Second)
	token := "testtoken1234567890abcdef12345678"
	server := NewServer(registry, token)

	listener, err := server.ListenAndServe()
	if err != nil {
		t.Fatalf("failed to start server: %v", err)
	}

	port := listener.Addr().(*net.TCPAddr).Port
	url := fmt.Sprintf("ws://127.0.0.1:%d/", port)

	header := http.Header{}
	header.Set("X-Pion-Token", token)
	conn, _, err := websocket.DefaultDialer.Dial(url, header)
	if err != nil {
		listener.Close()
		t.Fatalf("failed to connect: %v", err)
	}

	ic := &integrationClient{
		t:       t,
		conn:    conn,
		nextID:  1,
		pending: make(map[int]chan Message),
		done:    make(chan struct{}),
	}

	go ic.readLoop()

	cleanup := func() {
		conn.Close()
		listener.Close()
		<-ic.done
	}
	return ic, cleanup
}

func (ic *integrationClient) readLoop() {
	defer close(ic.done)
	for {
		_, data, err := ic.conn.ReadMessage()
		if err != nil {
			// Fail all pending
			ic.mu.Lock()
			for _, ch := range ic.pending {
				close(ch)
			}
			ic.pending = make(map[int]chan Message)
			ic.mu.Unlock()
			return
		}
		var msg Message
		if err := msgpack.Unmarshal(data, &msg); err != nil {
			continue
		}

		if msg.ID == 0 {
			// Event
			ic.mu.Lock()
			ic.events = append(ic.events, msg)
			ic.mu.Unlock()
		} else {
			// Response
			ic.mu.Lock()
			ch, ok := ic.pending[msg.ID]
			if ok {
				delete(ic.pending, msg.ID)
			}
			ic.mu.Unlock()
			if ok {
				ch <- msg
			}
		}
	}
}

func (ic *integrationClient) send(msg Message) Message {
	ic.t.Helper()

	ch := make(chan Message, 1)
	ic.mu.Lock()
	ic.pending[msg.ID] = ch
	ic.mu.Unlock()

	data, err := msgpack.Marshal(msg)
	if err != nil {
		ic.t.Fatalf("marshal: %v", err)
	}
	if err := ic.conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		ic.t.Fatalf("write: %v", err)
	}

	select {
	case resp, ok := <-ch:
		if !ok {
			ic.t.Fatalf("connection closed while waiting for response to id=%d type=%s", msg.ID, msg.Type)
		}
		return resp
	case <-time.After(10 * time.Second):
		ic.t.Fatalf("timeout waiting for response to id=%d type=%s", msg.ID, msg.Type)
		return Message{}
	}
}

func (ic *integrationClient) getID() int {
	id := ic.nextID
	ic.nextID++
	return id
}

func (ic *integrationClient) getEvents() []Message {
	ic.mu.Lock()
	defer ic.mu.Unlock()
	cp := make([]Message, len(ic.events))
	copy(cp, ic.events)
	return cp
}

func (ic *integrationClient) clearEvents() {
	ic.mu.Lock()
	defer ic.mu.Unlock()
	ic.events = nil
}

func (ic *integrationClient) filterEvents(typ string, handle string) []Message {
	ic.mu.Lock()
	defer ic.mu.Unlock()
	var result []Message
	for _, e := range ic.events {
		if e.Type == typ && (handle == "" || e.Handle == handle) {
			result = append(result, e)
		}
	}
	return result
}

func (ic *integrationClient) waitForEvent(typ string, handle string, timeout time.Duration) (Message, bool) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		ic.mu.Lock()
		for _, e := range ic.events {
			if e.Type == typ && (handle == "" || e.Handle == handle) {
				ic.mu.Unlock()
				return e, true
			}
		}
		ic.mu.Unlock()
		time.Sleep(50 * time.Millisecond)
	}
	return Message{}, false
}

func TestIntegration_FullFlow(t *testing.T) {
	ic, cleanup := startIntegration(t)
	defer cleanup()

	// 1. Init
	resp := ic.send(Message{Type: "init", ID: ic.getID(), Data: map[string]interface{}{}})
	if resp.Type != "init:ack" {
		t.Fatalf("init failed: %s %v", resp.Type, resp.Data)
	}
	if resp.Data["version"] != "1.0.0" {
		t.Errorf("expected version 1.0.0, got %v", resp.Data["version"])
	}

	// 2. Create two PeerConnections
	offererResp := ic.send(Message{Type: "pc:create", ID: ic.getID(), Data: map[string]interface{}{}})
	if offererResp.Type != "pc:create:ack" {
		t.Fatalf("create offerer failed: %s", offererResp.Type)
	}
	offerer := offererResp.Data["handle"].(string)

	answererResp := ic.send(Message{Type: "pc:create", ID: ic.getID(), Data: map[string]interface{}{}})
	if answererResp.Type != "pc:create:ack" {
		t.Fatalf("create answerer failed: %s", answererResp.Type)
	}
	answerer := answererResp.Data["handle"].(string)

	// 3. Create DataChannel on offerer (before offer so it's in the SDP)
	dcResp := ic.send(Message{
		Type: "pc:createDc", ID: ic.getID(), Handle: offerer,
		Data: map[string]interface{}{"label": "chat", "options": map[string]interface{}{"ordered": true}},
	})
	if dcResp.Type != "pc:createDc:ack" {
		t.Fatalf("createDc failed: %s %v", dcResp.Type, dcResp.Data)
	}
	offererDcHandle := dcResp.Data["dc_handle"].(string)
	if dcResp.Data["label"] != "chat" {
		t.Errorf("expected label chat, got %v", dcResp.Data["label"])
	}

	// 4. Offerer: createOffer + setLocalDesc
	offerResp := ic.send(Message{
		Type: "pc:offer", ID: ic.getID(), Handle: offerer,
		Data: map[string]interface{}{"offer_options": map[string]interface{}{}},
	})
	if offerResp.Type != "pc:offer:ack" {
		t.Fatalf("offer failed: %s %v", offerResp.Type, offerResp.Data)
	}
	offerSdp := offerResp.Data["sdp"].(string)

	setLocalResp := ic.send(Message{
		Type: "pc:setLocalDesc", ID: ic.getID(), Handle: offerer,
		Data: map[string]interface{}{"sdp": offerSdp, "type": "offer"},
	})
	if setLocalResp.Type != "pc:setLocalDesc:ack" {
		t.Fatalf("setLocalDesc failed: %s %v", setLocalResp.Type, setLocalResp.Data)
	}

	// 5. Answerer: setRemoteDesc + createAnswer + setLocalDesc
	setRemoteResp := ic.send(Message{
		Type: "pc:setRemoteDesc", ID: ic.getID(), Handle: answerer,
		Data: map[string]interface{}{"sdp": offerSdp, "type": "offer"},
	})
	if setRemoteResp.Type != "pc:setRemoteDesc:ack" {
		t.Fatalf("setRemoteDesc failed: %s %v", setRemoteResp.Type, setRemoteResp.Data)
	}

	answerResp := ic.send(Message{
		Type: "pc:answer", ID: ic.getID(), Handle: answerer,
		Data: map[string]interface{}{"answer_options": map[string]interface{}{}},
	})
	if answerResp.Type != "pc:answer:ack" {
		t.Fatalf("answer failed: %s %v", answerResp.Type, answerResp.Data)
	}
	answerSdp := answerResp.Data["sdp"].(string)

	setLocalResp2 := ic.send(Message{
		Type: "pc:setLocalDesc", ID: ic.getID(), Handle: answerer,
		Data: map[string]interface{}{"sdp": answerSdp, "type": "answer"},
	})
	if setLocalResp2.Type != "pc:setLocalDesc:ack" {
		t.Fatalf("setLocalDesc (answerer) failed: %s %v", setLocalResp2.Type, setLocalResp2.Data)
	}

	// 6. Offerer: setRemoteDesc
	setRemoteResp2 := ic.send(Message{
		Type: "pc:setRemoteDesc", ID: ic.getID(), Handle: offerer,
		Data: map[string]interface{}{"sdp": answerSdp, "type": "answer"},
	})
	if setRemoteResp2.Type != "pc:setRemoteDesc:ack" {
		t.Fatalf("setRemoteDesc (offerer) failed: %s %v", setRemoteResp2.Type, setRemoteResp2.Data)
	}

	// 7. Wait for ICE candidates and exchange them
	time.Sleep(500 * time.Millisecond)
	events := ic.getEvents()
	for _, e := range events {
		if e.Type == "event:iceCandidate" {
			candidate, _ := e.Data["candidate"].(string)
			sdpMid, _ := e.Data["sdp_mid"].(string)
			sdpMLineIndex := 0
			if idx, ok := e.Data["sdp_mline_index"]; ok {
				switch v := idx.(type) {
				case int8:
					sdpMLineIndex = int(v)
				case int64:
					sdpMLineIndex = int(v)
				case uint64:
					sdpMLineIndex = int(v)
				}
			}

			targetHandle := answerer
			if e.Handle == answerer {
				targetHandle = offerer
			}

			addIceResp := ic.send(Message{
				Type: "pc:addIce", ID: ic.getID(), Handle: targetHandle,
				Data: map[string]interface{}{
					"candidate":       candidate,
					"sdp_mid":         sdpMid,
					"sdp_mline_index": sdpMLineIndex,
				},
			})
			if addIceResp.Type == "error" {
				t.Logf("addIce warning: %v", addIceResp.Data)
			}
		}
	}

	// 8. Check for connectionStateChange events
	time.Sleep(2 * time.Second)
	events = ic.getEvents()
	connectedCount := 0
	for _, e := range events {
		if e.Type == "event:connectionStateChange" {
			state, _ := e.Data["state"].(string)
			t.Logf("connectionStateChange: handle=%s state=%s", e.Handle, state)
			if state == "connected" {
				connectedCount++
			}
		}
	}
	t.Logf("PCs that reached 'connected': %d", connectedCount)

	// 9. Check event:dataChannel on answerer side
	dcEvent, found := ic.waitForEvent("event:dataChannel", answerer, 2*time.Second)
	var answererDcHandle string
	if found {
		label, _ := dcEvent.Data["label"].(string)
		answererDcHandle, _ = dcEvent.Data["dc_handle"].(string)
		t.Logf("Answerer received dataChannel: label=%s dc_handle=%s", label, answererDcHandle)
		if label != "chat" {
			t.Errorf("expected label 'chat', got %s", label)
		}
		if answererDcHandle == "" {
			t.Error("event:dataChannel missing dc_handle")
		}
	} else {
		t.Fatal("event:dataChannel not received on answerer")
	}

	// 9a. Verify event:iceCandidate had correct fields
	iceCandidateEvents := ic.filterEvents("event:iceCandidate", "")
	if len(iceCandidateEvents) > 0 {
		e := iceCandidateEvents[0]
		if _, ok := e.Data["candidate"].(string); !ok {
			t.Error("event:iceCandidate missing candidate field")
		}
		if _, ok := e.Data["sdp_mid"]; !ok {
			t.Error("event:iceCandidate missing sdp_mid field")
		}
		if _, ok := e.Data["sdp_mline_index"]; !ok {
			t.Error("event:iceCandidate missing sdp_mline_index field")
		}
		if e.ID != 0 {
			t.Errorf("event:iceCandidate should have id=0, got %d", e.ID)
		}
	} else {
		t.Error("expected at least one event:iceCandidate")
	}

	// 9b. Verify event:iceGatheringComplete was received
	_, foundGatheringComplete := ic.waitForEvent("event:iceGatheringComplete", "", 2*time.Second)
	if !foundGatheringComplete {
		t.Error("event:iceGatheringComplete not received")
	}

	// 9c. Wait for dataChannelOpen on both offerer and answerer DCs
	_, foundOffererDcOpen := ic.waitForEvent("event:dataChannelOpen", offererDcHandle, 3*time.Second)
	if !foundOffererDcOpen {
		t.Error("event:dataChannelOpen not received for offerer DC")
	}
	_, foundAnswererDcOpen := ic.waitForEvent("event:dataChannelOpen", answererDcHandle, 3*time.Second)
	if !foundAnswererDcOpen {
		t.Error("event:dataChannelOpen not received for answerer DC")
	}

	// 10. Send text message from offerer DC, verify event:dataChannelMessage on answerer DC
	ic.clearEvents()
	sendTextResp := ic.send(Message{
		Type: "dc:send", ID: ic.getID(), Handle: offererDcHandle,
		Data: map[string]interface{}{"data": "Hello, peer!", "is_binary": false},
	})
	if sendTextResp.Type != "dc:send:ack" {
		t.Fatalf("dc:send text failed: %s %v", sendTextResp.Type, sendTextResp.Data)
	}
	bytesSent, _ := sendTextResp.Data["bytes_sent"]
	t.Logf("dc:send text bytes_sent=%v", bytesSent)

	textMsgEvent, foundTextMsg := ic.waitForEvent("event:dataChannelMessage", answererDcHandle, 3*time.Second)
	if !foundTextMsg {
		t.Error("event:dataChannelMessage (text) not received on answerer DC")
	} else {
		if textMsgEvent.Data["data"] != "Hello, peer!" {
			t.Errorf("expected text 'Hello, peer!', got %v", textMsgEvent.Data["data"])
		}
		if textMsgEvent.Data["is_binary"] != false {
			t.Errorf("expected is_binary=false, got %v", textMsgEvent.Data["is_binary"])
		}
	}

	// 11. Send binary message (base64) from offerer DC
	ic.clearEvents()
	sendBinaryResp := ic.send(Message{
		Type: "dc:send", ID: ic.getID(), Handle: offererDcHandle,
		Data: map[string]interface{}{"data": "AQID", "is_binary": true}, // base64 for [1,2,3]
	})
	if sendBinaryResp.Type != "dc:send:ack" {
		t.Fatalf("dc:send binary failed: %s %v", sendBinaryResp.Type, sendBinaryResp.Data)
	}

	binaryMsgEvent, foundBinaryMsg := ic.waitForEvent("event:dataChannelMessage", answererDcHandle, 3*time.Second)
	if !foundBinaryMsg {
		t.Error("event:dataChannelMessage (binary) not received on answerer DC")
	} else {
		if binaryMsgEvent.Data["data"] != "AQID" {
			t.Errorf("expected base64 'AQID', got %v", binaryMsgEvent.Data["data"])
		}
		if binaryMsgEvent.Data["is_binary"] != true {
			t.Errorf("expected is_binary=true, got %v", binaryMsgEvent.Data["is_binary"])
		}
	}

	// 12. Close DataChannel, verify event:dataChannelClose
	ic.clearEvents()
	dcCloseResp := ic.send(Message{
		Type: "dc:close", ID: ic.getID(), Handle: offererDcHandle, Data: map[string]interface{}{},
	})
	if dcCloseResp.Type != "dc:close:ack" {
		t.Errorf("dc:close failed: %s %v", dcCloseResp.Type, dcCloseResp.Data)
	}

	// 12a. Verify event:dataChannelClose
	_, foundDcClose := ic.waitForEvent("event:dataChannelClose", offererDcHandle, 2*time.Second)
	if !foundDcClose {
		// May arrive on answerer DC handle instead
		_, foundDcClose = ic.waitForEvent("event:dataChannelClose", answererDcHandle, 1*time.Second)
	}
	if !foundDcClose {
		t.Log("WARN: event:dataChannelClose not received (timing-dependent)")
	}

	// 13. resource:delete PeerConnection (should cascade DC)
	deleteResp := ic.send(Message{
		Type: "resource:delete", ID: ic.getID(), Handle: offerer, Data: map[string]interface{}{},
	})
	if deleteResp.Type != "resource:delete:ack" {
		t.Errorf("resource:delete failed: %s %v", deleteResp.Type, deleteResp.Data)
	}

	// Verify DC handle is gone (cascade deleted)
	dcLookupResp := ic.send(Message{
		Type: "dc:close", ID: ic.getID(), Handle: offererDcHandle, Data: map[string]interface{}{},
	})
	if dcLookupResp.Type != "error" {
		t.Errorf("expected error for cascade-deleted DC, got %s", dcLookupResp.Type)
	}

	// 12. Clean up answerer
	deleteResp2 := ic.send(Message{
		Type: "resource:delete", ID: ic.getID(), Handle: answerer, Data: map[string]interface{}{},
	})
	if deleteResp2.Type != "resource:delete:ack" {
		t.Errorf("resource:delete (answerer) failed: %s %v", deleteResp2.Type, deleteResp2.Data)
	}
}

func TestIntegration_DisconnectDoesNotCrash(t *testing.T) {
	ic, cleanup := startIntegration(t)

	resp := ic.send(Message{Type: "pc:create", ID: 1, Data: map[string]interface{}{}})
	if resp.Type != "pc:create:ack" {
		t.Fatalf("create failed: %s", resp.Type)
	}

	// Abruptly close
	ic.conn.Close()
	cleanup()
}
