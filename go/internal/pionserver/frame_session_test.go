package pionserver

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/vmihailenco/msgpack/v5"
)

// testFrameClient drives a FrameSession the way the Dart FFI transport does:
// msgpack frames in, msgpack frames out, acks correlated by request id.
type testFrameClient struct {
	t      *testing.T
	fs     *FrameSession
	mu     sync.Mutex
	nextID int
	acks   map[int]chan Message
	events chan Message
}

func newTestFrameClient(t *testing.T, s *Server) *testFrameClient {
	c := &testFrameClient{t: t, acks: map[int]chan Message{}, events: make(chan Message, 256), nextID: 1}
	c.fs = s.NewFrameSession(func(frame []byte) {
		var m Message
		if err := msgpack.Unmarshal(frame, &m); err != nil {
			t.Errorf("unmarshal outbound frame: %v", err)
			return
		}
		c.mu.Lock()
		ch, ok := c.acks[m.ID]
		delete(c.acks, m.ID)
		c.mu.Unlock()
		if ok && m.ID != 0 {
			ch <- m
			return
		}
		c.events <- m
	})
	t.Cleanup(c.fs.Close)
	return c
}

func (c *testFrameClient) request(typ, handle string, data map[string]interface{}) Message {
	c.t.Helper()
	c.mu.Lock()
	id := c.nextID
	c.nextID++
	ch := make(chan Message, 1)
	c.acks[id] = ch
	c.mu.Unlock()
	frame, err := msgpack.Marshal(Message{Type: typ, ID: id, Handle: handle, Data: data})
	if err != nil {
		c.t.Fatal(err)
	}
	if err := c.fs.Push(frame); err != nil {
		c.t.Fatal(err)
	}
	select {
	case m := <-ch:
		if m.Type == "error" {
			c.t.Fatalf("%s: error response %v", typ, m.Data)
		}
		return m
	case <-time.After(5 * time.Second):
		c.t.Fatalf("%s: no ack", typ)
		return Message{}
	}
}

// waitEvent returns the first event matching typ, passing earlier ones to keep.
func (c *testFrameClient) waitEvent(typ string, keep func(Message)) Message {
	c.t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case m := <-c.events:
			if m.Type == typ {
				return m
			}
			if keep != nil {
				keep(m)
			}
		case <-deadline:
			c.t.Fatalf("timed out waiting for %s", typ)
			return Message{}
		}
	}
}

func TestFrameSession_InitAck(t *testing.T) {
	s := NewServer(NewRegistry(), "")
	c := newTestFrameClient(t, s)
	if m := c.request("init", "", map[string]interface{}{}); m.Type != "init:ack" {
		t.Fatalf("expected init:ack, got %s", m.Type)
	}
}

func TestFrameSession_MalformedFrameThenContinues(t *testing.T) {
	s := NewServer(NewRegistry(), "")
	c := newTestFrameClient(t, s)
	if err := c.fs.Push([]byte{0xc1}); err != nil { // 0xc1 is never valid msgpack
		t.Fatal(err)
	}
	if m := c.waitEvent("error", nil); m.Data["code"] != "INVALID_REQUEST" {
		t.Fatalf("expected INVALID_REQUEST, got %v", m.Data)
	}
	if m := c.request("init", "", map[string]interface{}{}); m.Type != "init:ack" {
		t.Fatalf("session did not continue after bad frame: %s", m.Type)
	}
}

func TestFrameSession_PushAfterClose(t *testing.T) {
	s := NewServer(NewRegistry(), "")
	fs := s.NewFrameSession(func([]byte) {})
	fs.Close()
	fs.Close() // idempotent
	if err := fs.Push([]byte{0x80}); err != ErrSessionClosed {
		t.Fatalf("expected ErrSessionClosed, got %v", err)
	}
}

// deliver must never run after Close returns: the shared-library transport
// frees the Dart callback right after closing the session.
func TestFrameSession_NoDeliverAfterClose(t *testing.T) {
	s := NewServer(NewRegistry(), "")
	for i := 0; i < 200; i++ {
		var closed atomic.Bool
		fs := s.NewFrameSession(func([]byte) {
			if closed.Load() {
				t.Error("deliver called after Close returned")
			}
		})
		init, _ := msgpack.Marshal(Message{Type: "init", ID: 1, Data: map[string]interface{}{}})
		for j := 0; j < 20; j++ {
			_ = fs.Push(init)
		}
		fs.Close()
		closed.Store(true)
		time.Sleep(time.Millisecond)
	}
}

// Two sessions on one server negotiate a real PeerConnection pair over
// loopback and exchange a DataChannel message — the whole protocol, no socket.
func TestFrameSession_DataChannelLoopback(t *testing.T) {
	s := NewServer(NewRegistry(), "")
	a := newTestFrameClient(t, s)
	b := newTestFrameClient(t, s)
	// Loopback-only ICE, as the WebSocket system tests do: deterministic setup
	// on hosts with many interfaces, including under -race.
	a.request("init", "", map[string]interface{}{"settings_engine": loopbackSettingsEngine()})
	b.request("init", "", map[string]interface{}{"settings_engine": loopbackSettingsEngine()})

	pcA := a.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	pcB := b.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	dcA := a.request("pc:createDc", pcA, map[string]interface{}{"label": "t", "options": map[string]interface{}{"ordered": true}}).Data["dc_handle"].(string)

	gather := func(c *testFrameClient) []map[string]interface{} {
		var cands []map[string]interface{}
		c.waitEvent("event:iceGatheringComplete", func(m Message) {
			if m.Type == "event:iceCandidate" {
				cands = append(cands, m.Data)
			}
		})
		return cands
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
	remote := b.waitEvent("event:dataChannel", nil)
	if remote.Data["label"] != "t" {
		t.Fatalf("remote label = %v", remote.Data["label"])
	}

	a.request("dc:send", dcA, map[string]interface{}{"data": "hello"})
	got := b.waitEvent("event:dataChannelMessage", nil)
	if got.Data["data"] != "hello" {
		t.Fatalf("received %v", got.Data["data"])
	}
}
