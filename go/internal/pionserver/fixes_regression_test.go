package pionserver

// Regression tests for the 2026-07 audit fixes. Each test targets one
// verified defect and is written to fail on the pre-fix code:
//
//  1. TestRegression_DisconnectDuringSendsDoesNotCrash — dc:send acks emitted
//     after the WebSocket dropped used to panic ("send on closed channel")
//     and kill the process.
//  2. TestRegression_CrossConnectionSendAckRouting — acks for dc:send issued
//     on connection B used to be routed to the connection that created the
//     DC (A), so B never saw them.
//  3. TestRegression_TouchRefreshesParentChain — Touch only refreshed the
//     child handle, so the TTL sweeper deleted the parent PC (cascading away
//     the still-active DC).
//  4. TestRegression_EventDeliveryRefreshesTTL — outbound events did not
//     count as activity, so receive-only resources were TTL-reaped.
//  5. TestRegression_DeleteDoesNotBlockLookup — Delete held the registry
//     lock across resource.Close(), stalling all lookups.
//  6. TestRegression_TraceIndexNotAllocatedWhenDisabled /
//     TestRegression_TraceIndexReleasedOnDelete — the trace handle→slot map
//     grew unboundedly across DC churn.
//  7. TestRegression_TextDoesNotOvertakeQueuedBinary — text dc:send ran
//     inline while binary went through the per-DC queue, reordering frames.

import (
	"fmt"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// setLastSeenForTest and getLastSeenForTest wrap access to the registry's
// per-handle atomic lastSeen stamps (the map is guarded by r.mu).
func setLastSeenForTest(r *Registry, handle string, at time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if st, ok := r.lastSeen[handle]; ok {
		st.Store(at.UnixNano())
	}
}

func getLastSeenForTest(r *Registry, handle string) time.Time {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if st, ok := r.lastSeen[handle]; ok {
		return time.Unix(0, st.Load())
	}
	return time.Time{}
}

// startIntegrationServer starts a server and returns its url+token so several
// clients can connect to the same registry (unlike startIntegration, which
// couples one client to one server).
func startIntegrationServer(t *testing.T) (url, token string) {
	t.Helper()
	registry := NewRegistry()
	token = "testtoken1234567890abcdef12345678"
	server := NewServer(registry, token)
	listener, err := server.ListenAndServe()
	if err != nil {
		t.Fatalf("failed to start server: %v", err)
	}
	t.Cleanup(func() { listener.Close() })
	return fmt.Sprintf("ws://127.0.0.1:%d/", listener.Addr().(*net.TCPAddr).Port), token
}

// connectIntegrationClient attaches a new integrationClient to an existing server.
func connectIntegrationClient(t *testing.T, url, token string) *integrationClient {
	t.Helper()
	header := http.Header{}
	header.Set("X-Pion-Token", token)
	conn, _, err := websocket.DefaultDialer.Dial(url, header)
	if err != nil {
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
	t.Cleanup(func() {
		conn.Close()
		<-ic.done
	})
	return ic
}

// --- 1. Disconnect while awaitDrain sends are in flight must not crash ---

func TestRegression_DisconnectDuringSendsDoesNotCrash(t *testing.T) {
	url, token := startIntegrationServer(t)
	ic := connectIntegrationClient(t, url, token)

	dcHandle := setupConnectedDCPair(t, ic)
	if _, opened := ic.waitForEvent("event:dataChannelOpen", dcHandle, 5*time.Second); !opened {
		t.Fatal("DC did not open")
	}

	// Queue many awaitDrain sends so acks are still being emitted when the
	// connection drops. Pre-fix, the first ack after close(writeCh) panicked
	// on the per-DC goroutine (no recover) and killed the test process.
	payload := make([]byte, 128*1024)
	for i := 0; i < 24; i++ {
		ic.sendFireAndForget(Message{
			Type: "dc:send", ID: 1000 + i, Handle: dcHandle,
			Data: map[string]interface{}{"data": payload},
		})
	}
	// Abruptly drop the connection mid-drain.
	ic.conn.Close()

	// Give the per-DC goroutine time to emit acks into the dead connection.
	time.Sleep(1 * time.Second)

	// The server (and this process) must still be alive and serving.
	ic2 := connectIntegrationClient(t, url, token)
	resp := ic2.send(Message{Type: "init", ID: 1, Data: map[string]interface{}{}})
	if resp.Type != "init:ack" {
		t.Fatalf("server not responsive after mid-send disconnect: %s %v", resp.Type, resp.Data)
	}
}

// --- 2. dc:send from a second connection must be acked on that connection ---

func TestRegression_CrossConnectionSendAckRouting(t *testing.T) {
	url, token := startIntegrationServer(t)
	icA := connectIntegrationClient(t, url, token)

	dcHandle := setupConnectedDCPair(t, icA)
	if _, opened := icA.waitForEvent("event:dataChannelOpen", dcHandle, 5*time.Second); !opened {
		t.Fatal("DC did not open")
	}

	// Connection B sends on the DC that connection A created. The ack must
	// arrive on B (pre-fix it was emitted via A's writer).
	icB := connectIntegrationClient(t, url, token)
	resp := icB.send(Message{
		Type: "dc:send", ID: 7, Handle: dcHandle,
		Data: map[string]interface{}{"data": []byte{1, 2, 3}},
	})
	if resp.Type != "dc:send:ack" {
		t.Fatalf("expected dc:send:ack on issuing connection, got %s %v", resp.Type, resp.Data)
	}
}

// --- 3. Touch must refresh the parent chain ---

func TestRegression_TouchRefreshesParentChain(t *testing.T) {
	r := NewRegistry()
	pcHandle := r.Register("fake-pc")
	dcHandle := r.RegisterChild("fake-dc", pcHandle)

	// Age both handles past the TTL, then touch only the child.
	old := time.Now().Add(-10 * time.Minute)
	setLastSeenForTest(r, pcHandle, old)
	setLastSeenForTest(r, dcHandle, old)

	r.Touch(dcHandle)
	r.Cleanup(5 * time.Minute)

	if _, ok := r.Lookup(pcHandle); !ok {
		t.Error("parent PC was reaped even though its child DC is active")
	}
	if _, ok := r.Lookup(dcHandle); !ok {
		t.Error("touched DC was reaped")
	}
}

// --- 4. Outbound events must count as TTL activity ---

func TestRegression_EventDeliveryRefreshesTTL(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t)

	old := time.Now().Add(-10 * time.Minute)
	setLastSeenForTest(th.registry, pcHandle, old)

	// A receive-only resource produces outbound events but no inbound RPCs.
	th.handler.sendEvent(Event("event:dataChannelMessage", pcHandle, map[string]interface{}{}))

	seen := getLastSeenForTest(th.registry, pcHandle)
	if !seen.After(old) {
		t.Error("outbound event did not refresh lastSeen; receive-only resources will be TTL-reaped")
	}
}

// --- 5. Delete must not hold the registry lock across Close() ---

type slowCloser struct{ d time.Duration }

func (s *slowCloser) Close() error { time.Sleep(s.d); return nil }

func TestRegression_DeleteDoesNotBlockLookup(t *testing.T) {
	r := NewRegistry()
	slow := r.Register(&slowCloser{d: 800 * time.Millisecond})
	other := r.Register("other")

	deleteDone := make(chan struct{})
	go func() {
		r.Delete(slow)
		close(deleteDone)
	}()
	time.Sleep(50 * time.Millisecond) // let Delete reach Close()

	start := time.Now()
	if _, ok := r.Lookup(other); !ok {
		t.Fatal("other handle missing")
	}
	if elapsed := time.Since(start); elapsed > 200*time.Millisecond {
		t.Errorf("Lookup blocked %v behind a slow Close; registry lock is held across Close()", elapsed)
	}
	<-deleteDone
}

// --- 6. Trace index map must not grow unboundedly ---

func traceIndexLen() int {
	Trace.mu.Lock()
	defer Trace.mu.Unlock()
	return len(Trace.dcIndex)
}

func traceIndexHas(handle string) bool {
	Trace.mu.Lock()
	defer Trace.mu.Unlock()
	_, ok := Trace.dcIndex[handle]
	return ok
}

func TestRegression_TraceIndexNotAllocatedWhenDisabled(t *testing.T) {
	if Trace.Enabled() {
		t.Skip("tracing enabled by another test; gating not observable")
	}
	th := newTestHarness()
	pcHandle := th.createPC(t)
	resp := th.handler.HandleMessage(&Message{
		Type: "pc:createDc", ID: 2, Handle: pcHandle,
		Data: map[string]interface{}{"label": "t"},
	})
	if resp.Type != "pc:createDc:ack" {
		t.Fatalf("createDc failed: %s %v", resp.Type, resp.Data)
	}
	dcHandle := resp.Data["dc_handle"].(string)

	if traceIndexHas(dcHandle) {
		t.Error("trace index slot allocated for DC while tracing is disabled (unbounded growth across DC churn)")
	}
	th.registry.Delete(pcHandle)
}

func TestRegression_TraceIndexReleasedOnDelete(t *testing.T) {
	before := traceIndexLen()

	// Simulate churn: allocate and delete many DCs through the registry.
	th := newTestHarness()
	for i := 0; i < 5; i++ {
		pcHandle := th.createPC(t)
		resp := th.handler.HandleMessage(&Message{
			Type: "pc:createDc", ID: 100 + i, Handle: pcHandle,
			Data: map[string]interface{}{"label": "churn"},
		})
		dcHandle := resp.Data["dc_handle"].(string)
		// Force allocation the way the trace path does when enabled.
		Trace.DCIdx(dcHandle)
		if err := th.registry.Delete(pcHandle); err != nil {
			t.Fatalf("delete: %v", err)
		}
		if traceIndexHas(dcHandle) {
			t.Fatalf("trace index entry for %s not released on registry delete", dcHandle)
		}
	}

	if after := traceIndexLen(); after > before {
		t.Errorf("trace index grew from %d to %d across DC churn", before, after)
	}
}

// --- 7. Text sends must not overtake queued binary sends ---

func TestRegression_TextDoesNotOvertakeQueuedBinary(t *testing.T) {
	url, token := startIntegrationServer(t)
	ic := connectIntegrationClient(t, url, token)

	dcHandle := setupConnectedDCPair(t, ic)
	if _, opened := ic.waitForEvent("event:dataChannelOpen", dcHandle, 5*time.Second); !opened {
		t.Fatal("DC did not open")
	}

	// The receiving DC handle is on the answerer side.
	dcEvent, found := ic.waitForEvent("event:dataChannel", "", 3*time.Second)
	if !found {
		t.Fatal("no event:dataChannel for answerer")
	}
	answererDc := dcEvent.Data["dc_handle"].(string)

	ic.clearEvents()

	const nBinary = 12
	payload := make([]byte, 64*1024)
	for i := 0; i < nBinary; i++ {
		ic.sendFireAndForget(Message{
			Type: "dc:send", ID: 0, Handle: dcHandle,
			Data: map[string]interface{}{"data": payload},
		})
	}
	// Text issued after the binaries must arrive after them.
	ic.sendFireAndForget(Message{
		Type: "dc:send", ID: 0, Handle: dcHandle,
		Data: map[string]interface{}{"data": "the-text-frame"},
	})

	deadline := time.Now().Add(10 * time.Second)
	var order []bool // true = binary
	for time.Now().Before(deadline) && len(order) < nBinary+1 {
		order = order[:0]
		for _, e := range ic.filterEvents("event:dataChannelMessage", answererDc) {
			isBinary, _ := e.Data["is_binary"].(bool)
			order = append(order, isBinary)
		}
		if len(order) < nBinary+1 {
			time.Sleep(50 * time.Millisecond)
		}
	}
	if len(order) < nBinary+1 {
		t.Fatalf("only received %d of %d messages", len(order), nBinary+1)
	}
	for i := 0; i < nBinary; i++ {
		if !order[i] {
			t.Fatalf("text frame arrived at position %d, overtaking %d queued binary frames", i, nBinary-i)
		}
	}
	if order[nBinary] {
		t.Fatal("last frame should be the text frame")
	}
}

// atomic import keepalive (used by other tests in this package via Trace).
var _ = atomic.LoadInt32
