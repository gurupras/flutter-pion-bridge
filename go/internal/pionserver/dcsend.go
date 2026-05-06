package pionserver

import (
	"sync"

	"github.com/pion/webrtc/v4"
)

// DCConfig holds per-DataChannel send tunables.  Pass a customised value to
// NewHandler to override the defaults for all DataChannels created through
// that Handler.  Individual channels can further adjust the buffer threshold
// at runtime via dc:setBufferedAmountLowThreshold.
type DCConfig struct {
	// BufferedAmountLowThreshold is the low-water mark in bytes for the
	// native send buffer.  The dc:send ack (when AwaitDrain is true) is held
	// until pion's buffer drains to at or below this value.  Default: 512 KB.
	BufferedAmountLowThreshold uint64
	// SendQueueDepth is the capacity of the per-DC work channel.  It must
	// be >= 1.  Larger values reduce goroutine back-pressure at the cost of
	// additional memory per channel.  Default: 32.
	SendQueueDepth int
}

// DefaultDCConfig is the DCConfig used when none is specified.
var DefaultDCConfig = DCConfig{
	BufferedAmountLowThreshold: 512 * 1024,
	SendQueueDepth:             32,
}

// dcSendWork is one async send unit dispatched from the read-loop to the
// per-DC sender goroutine.
type dcSendWork struct {
	data       []byte
	msgID      int
	awaitDrain bool // if false, ack immediately after dc.Send without waiting for buffer drain
}

// DCSendState owns the per-DataChannel send queue, low-water condition
// variable, and shutdown signal.  The read loop pushes work; the sender
// goroutine drains it, calls dc.Send, optionally waits for the buffered
// amount to drop below `threshold`, and emits the async ack.
//
// Close is idempotent and unblocks any waiter.  We deliberately do NOT close
// the work channel — closing it would race with read-loop senders that have
// already looked the state up but not yet enqueued.  Instead, the sender
// goroutine watches `done` via a select and exits cleanly even with work
// still queued.
type DCSendState struct {
	work      chan dcSendWork
	done      chan struct{}
	cond      *sync.Cond
	threshold uint64
	closeOnce sync.Once
}

func newDCSendState(cfg DCConfig) *DCSendState {
	s := &DCSendState{
		work:      make(chan dcSendWork, cfg.SendQueueDepth),
		done:      make(chan struct{}),
		threshold: cfg.BufferedAmountLowThreshold,
	}
	s.cond = sync.NewCond(&sync.Mutex{})
	return s
}

// closeState marks the state shut down, broadcasts the cond so the sender
// goroutine wakes from any in-progress wait, and is safe to call multiple
// times (cascade delete + explicit close + dc.OnClose all converge here).
func (s *DCSendState) closeState() {
	s.closeOnce.Do(func() {
		close(s.done)
		s.cond.L.Lock()
		s.cond.Broadcast()
		s.cond.L.Unlock()
	})
}

// signalLow wakes the sender goroutine if it is parked waiting for the
// buffered amount to drop.  Called from pion's OnBufferedAmountLow callback.
func (s *DCSendState) signalLow() {
	s.cond.L.Lock()
	s.cond.Broadcast()
	s.cond.L.Unlock()
}

// waitForBuffer blocks until dc.BufferedAmount falls at or below the current
// threshold, or the state is closed.  Returns false when closed mid-wait.
func (s *DCSendState) waitForBuffer(dc *webrtc.DataChannel) bool {
	s.cond.L.Lock()
	defer s.cond.L.Unlock()
	if LifecycleLogEnabled() {
		lifeLogf("waitForBuffer enter buffered=%d threshold=%d", dc.BufferedAmount(), s.threshold)
	}
	parked := false
	for dc.BufferedAmount() > s.threshold {
		select {
		case <-s.done:
			if LifecycleLogEnabled() {
				lifeLogf("waitForBuffer exit (closed) buffered=%d", dc.BufferedAmount())
			}
			return false
		default:
		}
		if LifecycleLogEnabled() && !parked {
			lifeLogf("waitForBuffer parking on cond buffered=%d threshold=%d", dc.BufferedAmount(), s.threshold)
			parked = true
		}
		s.cond.Wait()
	}
	if LifecycleLogEnabled() {
		lifeLogf("waitForBuffer exit (drained) buffered=%d parked=%v", dc.BufferedAmount(), parked)
	}
	return true
}

// setThreshold updates the low-water threshold and wakes any current waiter
// (lowering the threshold may immediately satisfy the predicate).
func (s *DCSendState) setThreshold(t uint64) {
	s.cond.L.Lock()
	s.threshold = t
	s.cond.Broadcast()
	s.cond.L.Unlock()
}
