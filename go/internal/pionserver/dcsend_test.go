package pionserver

import (
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// TestDCSend_BackToBackSmallBinaryAcks verifies that two small binary frames
// sent back-to-back on the same DC both produce dc:send acks within 3 s.
//
// Regression target: with the ack-on-drain wait loop in waitForBuffer and
// pion's OnBufferedAmountLow only firing on above->below transitions, two
// consecutive small sends can deadlock when the second send's runDCSend
// enters cond.Wait() but no future drain transition occurs (both sends are
// small enough that BufferedAmount never rises above the threshold, so
// OnBufferedAmountLow never fires again).
//
// Pass criterion: both dc:send acks (msg ID 200 and 201) arrive within 3s.
// Fail criterion: only the first ack arrives (or neither).
func TestDCSend_BackToBackSmallBinaryAcks(t *testing.T) {
	th := newTestHarness()
	_, _, dcHandle := th.createConnectedPCPair(t)

	// Drain any pre-test events so we only count post-send acks.
	th.clearEvents()

	const (
		firstID  = 200
		secondID = 201
	)

	// Two small binary frames sent immediately back-to-back.
	first := []byte("first control message: small binary payload for back-to-back ack test")
	second := []byte("second control message: smaller")

	th.handler.HandleMessage(&Message{
		Type: "dc:send", ID: firstID, Handle: dcHandle,
		Data: map[string]interface{}{"data": first},
	})
	th.handler.HandleMessage(&Message{
		Type: "dc:send", ID: secondID, Handle: dcHandle,
		Data: map[string]interface{}{"data": second},
	})

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		got1, got2 := false, false
		for _, e := range th.getEvents() {
			if e.Type == "dc:send:ack" && e.Handle == dcHandle {
				if e.ID == firstID {
					got1 = true
				}
				if e.ID == secondID {
					got2 = true
				}
			}
		}
		if got1 && got2 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}

	got1, got2 := false, false
	for _, e := range th.getEvents() {
		if e.Type == "dc:send:ack" && e.Handle == dcHandle {
			if e.ID == firstID {
				got1 = true
			}
			if e.ID == secondID {
				got2 = true
			}
		}
	}
	t.Fatalf("expected both dc:send:ack within 3s; got first=%v second=%v "+
		"(deadlock in waitForBuffer for back-to-back small sends?)",
		got1, got2)
}

// TestDCSend_LargeThenSmallAcks exercises the wait-loop's intended path: the
// first send pushes BufferedAmount above threshold so waitForBuffer parks on
// cond.Wait(), then drains via OnBufferedAmountLow. The second small send
// should not be starved.
func TestDCSend_LargeThenSmallAcks(t *testing.T) {
	th := newTestHarness()
	_, _, dcHandle := th.createConnectedPCPair(t)

	// Lower the threshold so a 64KB send is enough to push BufferedAmount
	// above it and exercise the wait-then-wake codepath.
	thrResp := th.handler.HandleMessage(&Message{
		Type: "dc:setBufferedAmountLowThreshold", ID: 100, Handle: dcHandle,
		Data: map[string]interface{}{"threshold": int(8 * 1024)},
	})
	if thrResp.Type != "dc:setBufferedAmountLowThreshold:ack" {
		t.Fatalf("set-threshold failed: %s %v", thrResp.Type, thrResp.Data)
	}

	th.clearEvents()

	const (
		firstID  = 300
		secondID = 301
	)

	large := make([]byte, 64*1024)
	for i := range large {
		large[i] = byte(i)
	}
	small := []byte("trailer")

	th.handler.HandleMessage(&Message{
		Type: "dc:send", ID: firstID, Handle: dcHandle,
		Data: map[string]interface{}{"data": large},
	})
	th.handler.HandleMessage(&Message{
		Type: "dc:send", ID: secondID, Handle: dcHandle,
		Data: map[string]interface{}{"data": small},
	})

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		got1, got2 := false, false
		for _, e := range th.getEvents() {
			if e.Type == "dc:send:ack" && e.Handle == dcHandle {
				if e.ID == firstID {
					got1 = true
				}
				if e.ID == secondID {
					got2 = true
				}
			}
		}
		if got1 && got2 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}

	got1, got2 := false, false
	for _, e := range th.getEvents() {
		if e.Type == "dc:send:ack" && e.Handle == dcHandle {
			if e.ID == firstID {
				got1 = true
			}
			if e.ID == secondID {
				got2 = true
			}
		}
	}
	t.Fatalf("expected both dc:send:ack within 5s; got first=%v second=%v "+
		"(large-then-small drain path stuck?)",
		got1, got2)
}

// TestDCSend_WithinDCOrdering_FIFO is the regression test for the
// detached-enqueue race that previously let two back-to-back dc:send calls
// on the same DC reach state.work in undefined order (each call spawned its
// own scheduling goroutine).  An ordered DC must guarantee that the order
// dc.Send is invoked matches the order the WebSocket received the requests
// — anything else violates the SCTP ordering guarantee for callers that
// don't run their own reorder buffer.
//
// The test fires N small binary sends in tight succession with monotonically
// increasing msgIDs (and a 1-byte payload encoding the msgID-mod-256 so the
// receiver can verify on-the-wire order independently of the ack stream),
// then asserts both:
//   1. dc:send acks come back with msgIDs in the original order (sender side
//      ran dc.Send in order)
//   2. peer's OnMessage events deliver payloads in the original order (the
//      receiver actually saw them in order on the wire)
func TestDCSend_WithinDCOrdering_FIFO(t *testing.T) {
	th := newTestHarness()
	_, _, dcHandle := th.createConnectedPCPair(t)
	th.clearEvents()

	const (
		baseID = 500
		count  = 32 // exercises full state.work buffer depth
	)

	for i := 0; i < count; i++ {
		payload := []byte{byte(i)}
		th.handler.HandleMessage(&Message{
			Type: "dc:send", ID: baseID + i, Handle: dcHandle,
			Data: map[string]interface{}{"data": payload},
		})
	}

	// Wait up to 5s for `count` acks AND `count` deliveries.
	deadline := time.Now().Add(5 * time.Second)
	var ackOrder []int
	var msgOrder []int
	for time.Now().Before(deadline) {
		ackOrder = ackOrder[:0]
		msgOrder = msgOrder[:0]
		for _, e := range th.getEvents() {
			if e.Type == "dc:send:ack" && e.Handle == dcHandle {
				if e.ID >= baseID && e.ID < baseID+count {
					ackOrder = append(ackOrder, e.ID)
				}
			}
			if e.Type == "event:dataChannelMessage" && e.Handle != dcHandle {
				if raw, ok := e.Data["data"].([]byte); ok && len(raw) == 1 {
					msgOrder = append(msgOrder, int(raw[0]))
				}
			}
		}
		if len(ackOrder) >= count && len(msgOrder) >= count {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	if len(ackOrder) < count {
		t.Fatalf("expected %d acks within 5s, got %d (ackOrder=%v)", count, len(ackOrder), ackOrder)
	}
	if len(msgOrder) < count {
		t.Fatalf("expected %d delivered messages within 5s, got %d (msgOrder=%v)", count, len(msgOrder), msgOrder)
	}

	for i := 0; i < count; i++ {
		if ackOrder[i] != baseID+i {
			t.Fatalf("ack ordering broken at index %d: got msgID %d, expected %d (full order: %v)",
				i, ackOrder[i], baseID+i, ackOrder)
		}
		if msgOrder[i] != i {
			t.Fatalf("on-wire ordering broken at index %d: got payload %d, expected %d (full order: %v)",
				i, msgOrder[i], i, msgOrder)
		}
	}
}

// TestDCSendState_WaitForBuffer_ExitsWhenBelowThreshold is a fast unit-level
// check that waitForBuffer returns immediately when BufferedAmount is already
// at-or-below threshold — i.e. it must NEVER park on cond.Wait() without a
// real reason to wait.
func TestDCSendState_WaitForBuffer_ExitsWhenBelowThreshold(t *testing.T) {
	s := newDCSendState(DefaultDCConfig)
	defer s.closeState()

	// Threshold is 512 KB by default.  A nil DC would crash on
	// dc.BufferedAmount(); use a real but unused webrtc.API DC by creating
	// a PC + DC and reading its BufferedAmount (which starts at 0).
	api := webrtc.NewAPI()
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("NewPeerConnection: %v", err)
	}
	defer pc.Close()
	dc, err := pc.CreateDataChannel("t", nil)
	if err != nil {
		t.Fatalf("CreateDataChannel: %v", err)
	}

	if dc.BufferedAmount() > s.threshold {
		t.Fatalf("precondition: BufferedAmount %d > threshold %d on fresh DC",
			dc.BufferedAmount(), s.threshold)
	}

	// waitForBuffer must not block — no signalLow will ever fire.
	done := make(chan bool, 1)
	go func() { done <- s.waitForBuffer(dc) }()
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("waitForBuffer returned false (closed?) but state is open")
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("waitForBuffer hung even though BufferedAmount is below threshold")
	}
}

// TestDCSendState_CloseState_DoesNotDeadlock verifies that calling closeState
// while waitForBuffer is running does not deadlock. closeState closes the done
// channel and broadcasts on the cond; waitForBuffer must observe the closure
// and return false.  This exercises the "DC closed mid-wait" path without
// requiring a real WebRTC connection with actual buffered data.
func TestDCSendState_CloseState_DoesNotDeadlock(t *testing.T) {
	s := newDCSendState(DefaultDCConfig)

	api := webrtc.NewAPI()
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("NewPeerConnection: %v", err)
	}
	defer pc.Close()
	dc, err := pc.CreateDataChannel("t", nil)
	if err != nil {
		t.Fatalf("CreateDataChannel: %v", err)
	}

	// Start waitForBuffer then immediately signal closure.  On an unconnected
	// DC, BufferedAmount is always 0 so waitForBuffer returns without parking
	// (threshold default 512 KB > 0).  The goroutine should complete promptly.
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.waitForBuffer(dc)
	}()
	s.closeState() // idempotent; safe to call while waitForBuffer is running.
	s.closeState() // second call must not panic or deadlock.

	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("waitForBuffer did not return after closeState — deadlock?")
	}
}
