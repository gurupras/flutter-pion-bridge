package pionserver

import (
	"sync"
	"sync/atomic"

	"github.com/pion/webrtc/v4"
)

// TrackHandler receives a remote track on a PeerConnection the bridge owns.
// It runs on pion's track goroutine and owns reading the track from then on.
type TrackHandler func(pcHandle string, pc *webrtc.PeerConnection, track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver)

// Process-wide hooks for Go code linked into the same binary as the bridge
// (see package embed). They are process-wide, like the shared library's
// server, because an embedder cannot know which protocol session created a
// connection.
var (
	trackHook  atomic.Pointer[TrackHandler]
	closedHook atomic.Pointer[func(pcHandle string)]
)

// SetTrackHandler installs fn for every remote track (nil removes it).
func SetTrackHandler(fn TrackHandler) {
	if fn == nil {
		trackHook.Store(nil)
		return
	}
	trackHook.Store(&fn)
}

// SetPeerConnectionClosedHandler installs fn, called once per PeerConnection
// when it closes (nil removes it).
func SetPeerConnectionClosedHandler(fn func(pcHandle string)) {
	if fn == nil {
		closedHook.Store(nil)
		return
	}
	closedHook.Store(&fn)
}

// closedOnce dedupes the closed notification: pc:close, resource:delete, TTL
// cleanup and the Closed state change can all report the same connection.
var closedOnce sync.Map // pcHandle -> struct{}

func notifyPCClosed(pcHandle string) {
	if _, dup := closedOnce.LoadOrStore(pcHandle, struct{}{}); dup {
		return
	}
	if fn := closedHook.Load(); fn != nil {
		(*fn)(pcHandle)
	}
}
