package pionserver

import (
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

func mediaEngineCfg(video ...string) map[string]interface{} {
	vs := make([]interface{}, len(video))
	for i, v := range video {
		vs[i] = v
	}
	return map[string]interface{}{"video_codecs": vs, "audio_codecs": []interface{}{"opus"}}
}

func mLines(sdp string) (lines []string) {
	for _, l := range strings.Split(sdp, "\r\n") {
		if strings.HasPrefix(l, "m=") {
			lines = append(lines, l)
		}
	}
	return
}

// The offer advertises exactly the media_engine codecs, in the given order,
// and transceivers produce m-lines with the requested directions.
func TestMediaEngineAndTransceivers(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(&Message{Type: "pc:create", ID: 1, Data: map[string]interface{}{
		"media_engine": mediaEngineCfg("AV1", "VP9", "VP8"),
	}})
	if resp.Type != "pc:create:ack" {
		t.Fatalf("pc:create: %s %v", resp.Type, resp.Data)
	}
	pc := resp.Data["handle"].(string)

	for i, tr := range []struct{ kind, dir string }{
		{"video", "recvonly"}, {"audio", "recvonly"}, {"audio", "sendonly"},
	} {
		r := th.handler.HandleMessage(&Message{Type: "pc:addTransceiver", ID: 2, Handle: pc,
			Data: map[string]interface{}{"kind": tr.kind, "direction": tr.dir}})
		if r.Type != "pc:addTransceiver:ack" {
			t.Fatalf("addTransceiver %v: %s %v", tr, r.Type, r.Data)
		}
		if got := r.Data["index"]; got != i {
			t.Fatalf("index = %v, want %d", got, i)
		}
	}

	offer := th.handler.HandleMessage(&Message{Type: "pc:offer", ID: 3, Handle: pc, Data: map[string]interface{}{}})
	sdp := offer.Data["sdp"].(string)
	ms := mLines(sdp)
	if len(ms) != 3 || !strings.HasPrefix(ms[0], "m=video") || !strings.HasPrefix(ms[1], "m=audio") || !strings.HasPrefix(ms[2], "m=audio") {
		t.Fatalf("m-lines: %v", ms)
	}
	sections := strings.Split(sdp, "\r\nm=")
	for i, want := range []string{"a=recvonly", "a=recvonly", "a=sendonly"} {
		if !strings.Contains(sections[i+1], want) {
			t.Errorf("m-line %d missing %s", i, want)
		}
	}
	// Codec order in the video m-line: AV1 (45) > VP9 (98) > VP8 (96), with RTX.
	if !strings.HasPrefix(ms[0], "m=video 9 UDP/TLS/RTP/SAVPF 45 46 98 99 96 97") {
		t.Errorf("video payload order: %s", ms[0])
	}
	for _, banned := range []string{"H264", "H265"} {
		if strings.Contains(sdp, banned) {
			t.Errorf("offer advertises %s", banned)
		}
	}
	if !strings.Contains(sdp, "AV1/90000") || !strings.Contains(sdp, "VP9/90000") || !strings.Contains(sdp, "opus/48000/2") {
		t.Error("offer missing a registered codec")
	}
}

func TestMediaEngineRejectsUnknownCodec(t *testing.T) {
	th := newTestHarness()
	resp := th.handler.HandleMessage(&Message{Type: "pc:create", ID: 1, Data: map[string]interface{}{
		"media_engine": mediaEngineCfg("H264"),
	}})
	if resp.Type != "error" || resp.Data["code"] != "INVALID_MEDIA_ENGINE" {
		t.Fatalf("got %s %v", resp.Type, resp.Data)
	}
}

func TestAddTransceiverValidates(t *testing.T) {
	th := newTestHarness()
	pc := th.handler.HandleMessage(&Message{Type: "pc:create", ID: 1, Data: map[string]interface{}{}}).Data["handle"].(string)
	for _, data := range []map[string]interface{}{
		{"kind": "data", "direction": "recvonly"},
		{"kind": "video", "direction": "sideways"},
	} {
		if r := th.handler.HandleMessage(&Message{Type: "pc:addTransceiver", ID: 2, Handle: pc, Data: data}); r.Type != "error" {
			t.Errorf("%v accepted: %v", data, r.Data)
		}
	}
}

// Codec sets are part of the per-connection profile: different sets get
// different APIs, and a pc:create overriding only media_engine keeps init's
// settings_engine.
func TestMediaEngineIsPerConnection(t *testing.T) {
	th := newTestHarness()
	th.handler.HandleMessage(&Message{Type: "init", ID: 1, Data: map[string]interface{}{
		"settings_engine": map[string]interface{}{"detach_data_channels": true},
	}})
	create := func(me map[string]interface{}) string {
		return th.handler.HandleMessage(&Message{Type: "pc:create", ID: 2, Data: map[string]interface{}{"media_engine": me}}).Data["handle"].(string)
	}
	a, b, c := create(mediaEngineCfg("VP8")), create(mediaEngineCfg("AV1")), create(mediaEngineCfg("VP8"))
	if th.handler.pcProfile(a).api == th.handler.pcProfile(b).api {
		t.Error("different codec sets share an API")
	}
	if th.handler.pcProfile(a).api != th.handler.pcProfile(c).api {
		t.Error("identical codec sets should share an API")
	}
	if !th.handler.pcProfile(a).detach {
		t.Error("media_engine override dropped init's settings_engine")
	}
}

// A remote video track reaches the in-process handler with the right
// PeerConnection handle, clients get event:track, and closing the connection
// notifies the closed handler exactly once.
func TestTrackHookAndEvent(t *testing.T) {
	type got struct {
		pc, codec string
		packets   int
	}
	tracks := make(chan got, 1)
	SetTrackHandler(func(pcHandle string, _ *webrtc.PeerConnection, track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		go func() {
			n := 0
			for n < 5 {
				if _, _, err := track.ReadRTP(); err != nil {
					return
				}
				n++
			}
			tracks <- got{pcHandle, track.Codec().MimeType, n}
		}()
	})
	var closedMu sync.Mutex
	closed := map[string]int{}
	SetPeerConnectionClosedHandler(func(h string) { closedMu.Lock(); closed[h]++; closedMu.Unlock() })
	t.Cleanup(func() { SetTrackHandler(nil); SetPeerConnectionClosedHandler(nil) })

	s := NewServer(NewRegistry(), "")
	c := newTestFrameClient(t, s)
	c.request("init", "", map[string]interface{}{
		"settings_engine": loopbackSettingsEngine(),
		"media_engine":    mediaEngineCfg("VP8"),
	})
	pc := c.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	c.request("pc:addTransceiver", pc, map[string]interface{}{"kind": "video", "direction": "recvonly"})
	offer := c.request("pc:offer", pc, map[string]interface{}{}).Data["sdp"].(string)
	c.request("pc:setLocalDesc", pc, map[string]interface{}{"sdp": offer, "type": "offer"})
	var cands []map[string]interface{}
	c.waitEvent("event:iceGatheringComplete", func(m Message) {
		if m.Type == "event:iceCandidate" {
			cands = append(cands, m.Data)
		}
	})

	// A plain pion peer answers with a VP8 track.
	se := webrtc.SettingEngine{}
	se.SetInterfaceFilter(func(n string) bool { return n == "lo" })
	se.SetIncludeLoopbackCandidate(true)
	m := &webrtc.MediaEngine{}
	if err := m.RegisterDefaultCodecs(); err != nil {
		t.Fatal(err)
	}
	remote, err := webrtc.NewAPI(webrtc.WithSettingEngine(se), webrtc.WithMediaEngine(m)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Close()
	track, _ := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8}, "video", "s")
	if _, err := remote.AddTrack(track); err != nil {
		t.Fatal(err)
	}
	if err := remote.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
		t.Fatal(err)
	}
	answer, _ := remote.CreateAnswer(nil)
	gathered := webrtc.GatheringCompletePromise(remote)
	_ = remote.SetLocalDescription(answer)
	<-gathered
	for _, cand := range cands {
		mid, _ := cand["sdp_mid"].(string)
		_ = remote.AddICECandidate(webrtc.ICECandidateInit{Candidate: cand["candidate"].(string), SDPMid: &mid})
	}
	c.request("pc:setRemoteDesc", pc, map[string]interface{}{"sdp": remote.LocalDescription().SDP, "type": "answer"})

	stop := make(chan struct{})
	defer close(stop)
	go func() {
		keyframe := []byte{0x10, 0x02, 0x00, 0x9d, 0x01, 0x2a, 0x10, 0x00, 0x10, 0x00}
		for {
			select {
			case <-stop:
				return
			case <-time.After(20 * time.Millisecond):
				_ = track.WriteSample(media.Sample{Data: keyframe, Duration: 20 * time.Millisecond})
			}
		}
	}()

	ev := c.waitEvent("event:track", nil)
	if ev.Handle != pc || ev.Data["kind"] != "video" || ev.Data["codec"] != webrtc.MimeTypeVP8 {
		t.Fatalf("event:track = %s %v", ev.Handle, ev.Data)
	}
	select {
	case g := <-tracks:
		if g.pc != pc || g.codec != webrtc.MimeTypeVP8 {
			t.Fatalf("hook got %+v, want pc %s", g, pc)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("track handler received no RTP")
	}

	c.request("pc:close", pc, map[string]interface{}{})
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		closedMu.Lock()
		n := closed[pc]
		closedMu.Unlock()
		if n > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond) // let a duplicate (state change) arrive if it would
	closedMu.Lock()
	defer closedMu.Unlock()
	if closed[pc] != 1 {
		t.Fatalf("closed handler called %d times, want 1", closed[pc])
	}
}
