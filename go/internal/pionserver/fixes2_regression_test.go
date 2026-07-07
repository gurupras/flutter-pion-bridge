package pionserver

// Regression tests for the 2026-07-06 audit findings. Each test targets one
// verified defect and is written to fail on the pre-fix code:
//
//  1. TestRegression_CascadeDeleteCollectsAllChildren — collectLocked ranged
//     over r.children[handle] while each child's parent-removal shifted the
//     same backing array, so with 3+ children alternating ones were skipped:
//     never Closed, never removed from the registry, and their per-DC send
//     goroutines leaked forever.
//  2. TestRegression_CloseStateDrainsQueuedWork — closeState closed `done`
//     but never drained state.work, so queued dc:send items got neither ack
//     nor error and the caller's Dart Futures hung forever.
//  3. TestRegression_CleanupSparesConnectedIdlePC — lastSeen is refreshed
//     only by inbound RPCs and outbound events; a connected-but-quiet PC/DC
//     (no traffic, no state changes) aged past the TTL and was reaped by the
//     sweeper even though the WebSocket keepalive showed the client alive.
//     TestRegression_CleanupStillReapsAbandonedPC guards the other side: a
//     never-connected stale PC must still be reaped.

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// --- 1. Cascade delete must collect every child ---

type trackingCloser struct{ closed atomic.Bool }

func (c *trackingCloser) Close() error { c.closed.Store(true); return nil }

func TestRegression_CascadeDeleteCollectsAllChildren(t *testing.T) {
	r := NewRegistry()
	pcCloser := &trackingCloser{}
	pcHandle := r.Register(pcCloser)

	const n = 5
	kids := make([]*trackingCloser, n)
	handles := make([]string, n)
	states := make([]*DCSendState, n)
	for i := range kids {
		kids[i] = &trackingCloser{}
		handles[i] = r.RegisterChild(kids[i], pcHandle)
		states[i] = newDCSendState(DefaultDCConfig)
		if !r.RegisterDCSendState(handles[i], states[i]) {
			t.Fatalf("failed to register send state %d", i)
		}
	}

	if err := r.Delete(pcHandle); err != nil {
		t.Fatalf("delete: %v", err)
	}

	if !pcCloser.closed.Load() {
		t.Error("parent PC was not closed")
	}
	for i := range kids {
		if !kids[i].closed.Load() {
			t.Errorf("child %d was never closed (skipped by cascade)", i)
		}
		if _, ok := r.Lookup(handles[i]); ok {
			t.Errorf("child %d still present in registry after parent delete", i)
		}
		if _, ok := r.LookupDCSendState(handles[i]); ok {
			t.Errorf("child %d send state leaked in registry", i)
		}
		select {
		case <-states[i].done:
		default:
			t.Errorf("child %d send state not closed — its goroutine would leak forever", i)
		}
	}

	r.mu.Lock()
	nRes, nParent, nChildren, nStates := len(r.resources), len(r.parent), len(r.children), len(r.dcSendStates)
	r.mu.Unlock()
	if nRes != 0 || nParent != 0 || nChildren != 0 || nStates != 0 {
		t.Errorf("registry maps not empty after cascade delete: resources=%d parent=%d children=%d dcSendStates=%d",
			nRes, nParent, nChildren, nStates)
	}
}

// --- 2. closeState must fail queued work, not abandon it ---

func TestRegression_CloseStateDrainsQueuedWork(t *testing.T) {
	state := newDCSendState(DCConfig{BufferedAmountLowThreshold: 512, SendQueueDepth: 8})

	var mu sync.Mutex
	var responses []Message
	record := func(m Message) {
		mu.Lock()
		responses = append(responses, m)
		mu.Unlock()
	}

	// Simulate dc:send work that was enqueued but not yet picked up by the
	// sender goroutine when the DC is torn down (e.g. several sends issued
	// without awaiting, then dc:close).
	const queued = 3
	for i := 1; i <= queued; i++ {
		state.work <- dcSendWork{data: []byte{1}, msgID: 100 + i, awaitDrain: true, sendEvent: record}
	}

	state.closeState()

	mu.Lock()
	defer mu.Unlock()
	if len(responses) != queued {
		t.Fatalf("expected %d error responses for queued work, got %d — callers' Futures hang forever", queued, len(responses))
	}
	seen := map[int]bool{}
	for _, m := range responses {
		if m.Type != "error" {
			t.Errorf("expected error response, got %s", m.Type)
		}
		if code, _ := m.Data["code"].(string); code != "DC_CLOSED" {
			t.Errorf("expected DC_CLOSED, got %v", m.Data["code"])
		}
		seen[m.ID] = true
	}
	for i := 1; i <= queued; i++ {
		if !seen[100+i] {
			t.Errorf("queued msgID %d got no response", 100+i)
		}
	}
}

// --- 3. TTL sweeper must not reap connected-but-idle resources ---

func setLastSeenSweeperTest(r *Registry, handle string, at time.Time) {
	setLastSeenForTest(r, handle, at)
}

func TestRegression_CleanupSparesConnectedIdlePC(t *testing.T) {
	th := newTestHarness()
	offerer, answerer, dcHandle := th.createConnectedPCPair(t)

	// Simulate >TTL of total silence: no inbound RPCs, no outbound events.
	old := time.Now().Add(-10 * time.Minute)
	for _, h := range []string{offerer, answerer, dcHandle} {
		setLastSeenSweeperTest(th.registry, h, old)
	}

	th.registry.Cleanup(5 * time.Minute)

	for _, h := range []string{offerer, answerer, dcHandle} {
		if _, ok := th.registry.Lookup(h); !ok {
			t.Errorf("connected idle resource %s was reaped by the TTL sweeper", h)
		}
	}
	th.registry.Delete(offerer)
	th.registry.Delete(answerer)
}

func TestRegression_CleanupStillReapsAbandonedPC(t *testing.T) {
	th := newTestHarness()
	pcHandle := th.createPC(t) // never signaled, never connected

	setLastSeenSweeperTest(th.registry, pcHandle, time.Now().Add(-10*time.Minute))
	th.registry.Cleanup(5 * time.Minute)

	if _, ok := th.registry.Lookup(pcHandle); ok {
		t.Error("abandoned (never-connected) stale PC was not reaped")
	}
}
