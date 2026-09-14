// Package embed lets Go code linked into the same process as the bridge work
// with the media the bridge's PeerConnections receive.
//
// The protocol (WebSocket or shared-library frames) carries control: offers,
// ICE, data channels. Media is too heavy for it, so an application that needs
// to decode or play remote tracks links its own Go code with the bridge — in
// shared mode, one c-shared library containing package cshared plus this
// application code — and registers handlers here.
package embed

import (
	"github.com/gurupras/flutter-pion-bridge/go/internal/pionserver"
	"github.com/pion/webrtc/v4"
)

// OnTrack registers fn for every remote track on every PeerConnection the
// bridge owns in this process, identified by its protocol handle. fn owns
// reading the track and must not block (start a goroutine). Registering
// replaces the previous handler; nil removes it. Without a handler the bridge
// drains tracks itself. Either way clients receive event:track.
func OnTrack(fn func(pcHandle string, pc *webrtc.PeerConnection, track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver)) {
	if fn == nil {
		pionserver.SetTrackHandler(nil)
		return
	}
	pionserver.SetTrackHandler(fn)
}

// OnPeerConnectionClosed registers fn, called once when a PeerConnection
// closes for any reason, so per-connection state can be released. nil removes
// it.
func OnPeerConnectionClosed(fn func(pcHandle string)) {
	pionserver.SetPeerConnectionClosedHandler(fn)
}
