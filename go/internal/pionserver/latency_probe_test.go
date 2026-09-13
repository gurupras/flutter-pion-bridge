package pionserver

import (
	"os"
	"sort"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// One-way DataChannel latency through FrameSession (bridge protocol, no Dart)
// vs raw pion in the same process. Probe only: PROBE=1 go test -run TestProbe.
func TestProbeLatency(t *testing.T) {
	if os.Getenv("PROBE") == "" {
		t.Skip("set PROBE=1")
	}
	s := NewServer(NewRegistry(), "")
	a := newTestFrameClient(t, s)
	b := newTestFrameClient(t, s)
	a.request("init", "", map[string]interface{}{"settings_engine": loopbackSettingsEngine()})
	b.request("init", "", map[string]interface{}{"settings_engine": loopbackSettingsEngine()})
	pcA := a.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	pcB := b.request("pc:create", "", map[string]interface{}{}).Data["handle"].(string)
	dcA := a.request("pc:createDc", pcA, map[string]interface{}{"label": "t", "options": map[string]interface{}{"ordered": true}}).Data["dc_handle"].(string)
	gather := func(c *testFrameClient) (out []map[string]interface{}) {
		c.waitEvent("event:iceGatheringComplete", func(m Message) {
			if m.Type == "event:iceCandidate" {
				out = append(out, m.Data)
			}
		})
		return
	}
	offer := a.request("pc:offer", pcA, map[string]interface{}{}).Data["sdp"].(string)
	a.request("pc:setLocalDesc", pcA, map[string]interface{}{"sdp": offer, "type": "offer"})
	ca := gather(a)
	b.request("pc:setRemoteDesc", pcB, map[string]interface{}{"sdp": offer, "type": "offer"})
	answer := b.request("pc:answer", pcB, map[string]interface{}{}).Data["sdp"].(string)
	b.request("pc:setLocalDesc", pcB, map[string]interface{}{"sdp": answer, "type": "answer"})
	cb := gather(b)
	a.request("pc:setRemoteDesc", pcA, map[string]interface{}{"sdp": answer, "type": "answer"})
	for _, c := range ca {
		b.request("pc:addIce", pcB, c)
	}
	for _, c := range cb {
		a.request("pc:addIce", pcA, c)
	}
	a.waitEvent("event:dataChannelOpen", nil)
	b.waitEvent("event:dataChannel", nil)
	b.waitEvent("event:dataChannelOpen", nil)

	payload := make([]byte, 200)
	var lat []time.Duration
	for i := 0; i < 600; i++ {
		t0 := time.Now()
		a.request("dc:send", dcA, map[string]interface{}{"data": payload, "await_drain": false})
		b.waitEvent("event:dataChannelMessage", nil)
		lat = append(lat, time.Since(t0))
		time.Sleep(8 * time.Millisecond)
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	t.Logf("bridge FrameSession one-way (incl. ack): p50=%v p95=%v", lat[len(lat)/2], lat[len(lat)*95/100])

	// Raw pion, same settings shape (loopback), same process.
	se := webrtc.SettingEngine{}
	se.SetIncludeLoopbackCandidate(true)
	se.SetInterfaceFilter(func(n string) bool { return n == "lo" })
	api := webrtc.NewAPI(webrtc.WithSettingEngine(se))
	p1, _ := api.NewPeerConnection(webrtc.Configuration{})
	p2, _ := api.NewPeerConnection(webrtc.Configuration{})
	defer p1.Close()
	defer p2.Close()
	p1.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			_ = p2.AddICECandidate(c.ToJSON())
		}
	})
	p2.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			_ = p1.AddICECandidate(c.ToJSON())
		}
	})
	d1, _ := p1.CreateDataChannel("t", nil)
	open := make(chan struct{})
	d1.OnOpen(func() { close(open) })
	got := make(chan struct{}, 1)
	p2.OnDataChannel(func(d *webrtc.DataChannel) {
		d.OnMessage(func(webrtc.DataChannelMessage) { got <- struct{}{} })
	})
	o, _ := p1.CreateOffer(nil)
	_ = p1.SetLocalDescription(o)
	_ = p2.SetRemoteDescription(o)
	an, _ := p2.CreateAnswer(nil)
	_ = p2.SetLocalDescription(an)
	_ = p1.SetRemoteDescription(an)
	<-open
	time.Sleep(200 * time.Millisecond)
	lat = lat[:0]
	for i := 0; i < 600; i++ {
		t0 := time.Now()
		_ = d1.Send(payload)
		<-got
		lat = append(lat, time.Since(t0))
		time.Sleep(8 * time.Millisecond)
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	t.Logf("raw pion one-way: p50=%v p95=%v", lat[len(lat)/2], lat[len(lat)*95/100])
}
