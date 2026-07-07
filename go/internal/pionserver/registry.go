package pionserver

import (
	"fmt"
	"io"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/pion/webrtc/v4"
)

// Registry is a thread-safe handle map for WebRTC resources.
type Registry struct {
	mu        sync.RWMutex
	resources map[string]interface{}
	// parent tracks which PeerConnection owns a DataChannel (dc_handle -> pc_handle)
	parent map[string]string
	// children tracks DataChannels owned by a PeerConnection (pc_handle -> []dc_handle)
	children map[string][]string
	// dcSendStates holds per-DataChannel send state.  Stored globally (not
	// per-Handler) so dc:send works regardless of which WebSocket connection
	// issues the call — the registry, not the Handler, owns the DC's lifetime.
	dcSendStates map[string]*DCSendState

	// lastSeen holds one atomic unix-nano stamp per resource. The map itself
	// is structural state guarded by mu (entries added/removed with the
	// resource); the STAMPS are updated lock-free. Touch runs on every
	// inbound message and every outbound event, so an exclusive mutex here
	// was the single point all DC goroutines and the read loop serialized on.
	lastSeen map[string]*atomic.Int64
}

// NewRegistry creates an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		resources:    make(map[string]interface{}),
		lastSeen:     make(map[string]*atomic.Int64),
		parent:       make(map[string]string),
		children:     make(map[string][]string),
		dcSendStates: make(map[string]*DCSendState),
	}
}

// newStampLocked creates the lastSeen stamp for a handle. Caller holds r.mu.
func (r *Registry) newStampLocked(handle string) {
	st := &atomic.Int64{}
	st.Store(time.Now().UnixNano())
	r.lastSeen[handle] = st
}

// touchStamp refreshes a stamp, skipping the store when it is already less
// than a second old: TTLs are minutes, so sub-second precision buys nothing,
// and skipping keeps the per-message hot path read-mostly (no cache-line
// ping-pong between the read loop and event goroutines of a busy channel).
func touchStamp(st *atomic.Int64) {
	if st == nil {
		return
	}
	now := time.Now().UnixNano()
	if now-st.Load() > int64(time.Second) {
		st.Store(now)
	}
}

// RegisterDCSendState stores the send state for a DataChannel handle.
// Returns false if a state is already registered (caller must not start two
// goroutines for the same DC).
func (r *Registry) RegisterDCSendState(handle string, state *DCSendState) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.dcSendStates[handle]; exists {
		return false
	}
	r.dcSendStates[handle] = state
	return true
}

// LookupDCSendState returns the send state for a DataChannel handle, or false
// if none is registered.
func (r *Registry) LookupDCSendState(handle string) (*DCSendState, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	state, ok := r.dcSendStates[handle]
	return state, ok
}

// removeDCSendStateLocked removes and returns the send state for a
// DataChannel.  Caller must hold r.mu and is responsible for closing the
// returned state.
func (r *Registry) removeDCSendStateLocked(handle string) (*DCSendState, bool) {
	state, ok := r.dcSendStates[handle]
	if ok {
		delete(r.dcSendStates, handle)
	}
	return state, ok
}

// RemoveDCSendState removes and returns the send state for a DataChannel.
// Caller is responsible for calling .closeState() so the goroutine exits.
func (r *Registry) RemoveDCSendState(handle string) (*DCSendState, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.removeDCSendStateLocked(handle)
}

// generateHandle creates a UUID v4 hex string (32 chars, no hyphens).
func generateHandle() string {
	return strings.ReplaceAll(uuid.New().String(), "-", "")
}

// Register stores a resource and returns its handle.
func (r *Registry) Register(resource interface{}) string {
	handle := generateHandle()
	r.mu.Lock()
	r.resources[handle] = resource
	r.newStampLocked(handle)
	r.mu.Unlock()
	return handle
}

// RegisterChild stores a child resource (DataChannel) linked to a parent (PeerConnection).
func (r *Registry) RegisterChild(resource interface{}, parentHandle string) string {
	handle := generateHandle()
	r.mu.Lock()
	r.resources[handle] = resource
	r.parent[handle] = parentHandle
	r.children[parentHandle] = append(r.children[parentHandle], handle)
	r.newStampLocked(handle)
	r.mu.Unlock()
	return handle
}

// Lookup returns a resource by handle, updating lastSeen.
func (r *Registry) Lookup(handle string) (interface{}, bool) {
	r.mu.RLock()
	res, ok := r.resources[handle]
	st := r.lastSeen[handle]
	r.mu.RUnlock()
	if ok {
		touchStamp(st)
	}
	return res, ok
}

// Touch updates the lastSeen timestamp for a handle and its ancestors.
// Refreshing the parent chain matters because Cleanup cascade-deletes: an
// active DataChannel must keep its owning PeerConnection alive, otherwise
// the TTL sweeper would reap the PC (and with it the busy DC).
func (r *Registry) Touch(handle string) {
	r.mu.RLock()
	st, ok := r.lastSeen[handle]
	var chain []*atomic.Int64
	if ok {
		chain = append(chain, st)
		h := handle
		for {
			p, hasParent := r.parent[h]
			if !hasParent {
				break
			}
			chain = append(chain, r.lastSeen[p])
			h = p
		}
	}
	r.mu.RUnlock()
	for _, st := range chain {
		touchStamp(st)
	}
}

// Delete removes a resource and closes it if it implements io.Closer.
// If the resource is a PeerConnection, cascade-deletes its DataChannels.
// Closing happens outside the registry lock: pc.Close() can block for the
// full ICE/DTLS/SCTP teardown, and holding r.mu across it would stall every
// Lookup/Touch on the hot path (and could deadlock against pion callbacks).
func (r *Registry) Delete(handle string) error {
	var closers []io.Closer
	var states []*DCSendState
	r.mu.Lock()
	if _, ok := r.resources[handle]; !ok {
		r.mu.Unlock()
		return fmt.Errorf("handle not found: %s", handle)
	}
	r.collectLocked(handle, &closers, &states)
	r.mu.Unlock()
	closeCollected(handle, closers, states)
	return nil
}

// collectLocked detaches handle (and, recursively, its children) from all
// registry maps, accumulating the resources to be shut down by the caller
// after the lock is released. Caller must hold r.mu.
func (r *Registry) collectLocked(handle string, closers *[]io.Closer, states *[]*DCSendState) {
	res, ok := r.resources[handle]
	if !ok {
		return
	}

	// Cascade: children first (DataChannels of a PeerConnection). Detach the
	// children entry BEFORE recursing: each child's own parent-removal below
	// mutates r.children[handle] in place, and ranging over the live slice
	// while it shifts left skips every other child (leaking their pion
	// handles and send goroutines).
	if kids, ok := r.children[handle]; ok {
		delete(r.children, handle)
		for _, kid := range kids {
			r.collectLocked(kid, closers, states)
		}
	}

	if state, ok := r.removeDCSendStateLocked(handle); ok {
		*states = append(*states, state)
	}

	if closer, ok := res.(io.Closer); ok {
		*closers = append(*closers, closer)
	}

	// Clean up parent reference
	if parentHandle, ok := r.parent[handle]; ok {
		kids := r.children[parentHandle]
		for i, kid := range kids {
			if kid == handle {
				r.children[parentHandle] = append(kids[:i], kids[i+1:]...)
				break
			}
		}
		delete(r.parent, handle)
	}

	delete(r.resources, handle)
	delete(r.lastSeen, handle)

	// Free the trace slot so the handle→index map doesn't grow across DC churn.
	Trace.ReleaseDC(handle)
}

// closeCollected shuts down send states (stopping per-DC goroutines) before
// closing the underlying pion resources.
func closeCollected(handle string, closers []io.Closer, states []*DCSendState) {
	for _, state := range states {
		state.closeState()
	}
	for _, closer := range closers {
		if err := closer.Close(); err != nil {
			log.Printf("warning: error closing resource %s: %v", handle, err)
		}
	}
}

// Cleanup removes resources that haven't been seen for the given duration.
//
// A resource is spared (and its TTL refreshed) when its root PeerConnection
// is currently connected: lastSeen is only refreshed by inbound RPCs and
// outbound events, so a connected-but-quiet channel (e.g. a control DC idle
// while the user decides something) generates no registry activity at all —
// reaping it would tear down a healthy connection the WebSocket keepalive
// still shows as alive. A PC that has sat in any other state (new, failed,
// disconnected, closed) past the TTL with no activity is genuinely abandoned
// and is still reaped.
func (r *Registry) Cleanup(maxAge time.Duration) {
	now := time.Now().UnixNano()

	// One read-locked pass finds expired handles and resolves each one's
	// root resource. Liveness is checked OUTSIDE any registry lock:
	// pc.ConnectionState() calls into pion, whose callbacks call back into
	// the registry (Touch), and holding r.mu across the boundary invites
	// lock-order trouble.
	roots := make(map[string]interface{})
	var expired []string
	r.mu.RLock()
	for handle, st := range r.lastSeen {
		if now-st.Load() <= maxAge.Nanoseconds() {
			continue
		}
		expired = append(expired, handle)
		h := handle
		for {
			p, ok := r.parent[h]
			if !ok {
				break
			}
			h = p
		}
		if res, ok := r.resources[h]; ok {
			roots[handle] = res
		}
	}
	r.mu.RUnlock()
	if len(expired) == 0 {
		return
	}

	var reap, spared []string
	for _, handle := range expired {
		if isLivePeerConnection(roots[handle]) {
			spared = append(spared, handle)
		} else {
			reap = append(reap, handle)
		}
	}

	var closers []io.Closer
	var states []*DCSendState
	r.mu.Lock()
	for _, handle := range reap {
		// May already be gone via a parent's cascade — collectLocked no-ops.
		r.collectLocked(handle, &closers, &states)
	}
	r.mu.Unlock()
	closeCollected("cleanup", closers, states)

	// Refresh spared handles so the next sweep doesn't re-resolve them.
	for _, handle := range spared {
		r.Touch(handle)
	}
}

// isLivePeerConnection reports whether res is a PeerConnection with an
// established transport. Only Connected counts: Disconnected can in theory
// recover, but a channel that stays disconnected for a full TTL with zero
// activity is dead in practice.
func isLivePeerConnection(res interface{}) bool {
	pc, ok := res.(*webrtc.PeerConnection)
	return ok && pc.ConnectionState() == webrtc.PeerConnectionStateConnected
}

// StartCleanup runs a background goroutine that cleans up stale resources
// every interval. The returned stop function terminates the goroutine (used
// by mobile.Stop so repeated Start/Stop cycles don't accumulate tickers).
func (r *Registry) StartCleanup(interval, maxAge time.Duration) (stop func()) {
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				r.Cleanup(maxAge)
			}
		}
	}()
	var once sync.Once
	return func() { once.Do(func() { close(done) }) }
}
