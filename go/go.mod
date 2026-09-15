module github.com/gurupras/flutter-pion-bridge/go

go 1.25.0

require (
	github.com/google/uuid v1.6.0
	github.com/gorilla/websocket v1.5.3
	github.com/pion/datachannel v1.6.0
	github.com/pion/interceptor v0.1.45
	github.com/pion/webrtc/v4 v4.2.15
	github.com/vmihailenco/msgpack/v5 v5.4.1
	golang.org/x/mobile v0.0.0-20260410095206-2cfb76559b7b
)

require (
	github.com/pion/dtls/v3 v3.1.4 // indirect
	github.com/pion/ice/v4 v4.2.7 // indirect
	github.com/pion/logging v0.2.4 // indirect
	github.com/pion/mdns/v2 v2.1.0 // indirect
	github.com/pion/randutil v0.1.0 // indirect
	github.com/pion/rtcp v1.2.16 // indirect
	github.com/pion/rtp v1.10.2 // indirect
	github.com/pion/sctp v1.10.0 // indirect
	github.com/pion/sdp/v3 v3.0.18 // indirect
	github.com/pion/srtp/v3 v3.0.11 // indirect
	github.com/pion/stun/v3 v3.1.5 // indirect
	github.com/pion/transport/v4 v4.0.2 // indirect
	github.com/pion/turn/v5 v5.0.9 // indirect
	github.com/vmihailenco/tagparser/v2 v2.0.0 // indirect
	github.com/wlynxg/anet v0.0.5 // indirect
	golang.org/x/crypto v0.50.0 // indirect
	golang.org/x/mod v0.35.0 // indirect
	golang.org/x/net v0.53.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.43.0 // indirect
	golang.org/x/time v0.14.0 // indirect
	golang.org/x/tools v0.44.0 // indirect
)

// The vendored fork is upstream pion/sctp v1.10.0 plus one backport: upstream
// 597b321 "Bound outbound SACK packets by the MTU" (unreleased as of v1.11.1),
// in createSelectiveAckChunk / getGapAckBlocks. Without it a large receive
// window plus scattered loss produces SACKs the peer cannot read ("short
// buffer") and the association dies of T3 timeouts. Drop the fork once a
// pion/sctp release carries that commit.
//
// The fork no longer lowers rtoInitial/rtoMin: at rtoMin 100 ms, below the
// peer's 200 ms delayed-SACK timer, an association that idles between
// messages took spurious T3 timeouts and collapsed to a one-MTU cwnd.
//
// The replace is deliberately UNVERSIONED: a version-pinned replace silently
// no-ops when the sctp dependency is bumped, reverting the patch without any
// warning. If you upgrade pion/webrtc (and with it pion/sctp), rebase the
// backport onto the new sctp version, or remove the fork if upstream has it.
replace github.com/pion/sctp => ./pion-sctp-patched
