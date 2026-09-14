package pionserver

import (
	"fmt"
	"strings"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/nack"
	"github.com/pion/webrtc/v4"
)

// Payload types for codecs the bridge can register. Values follow pion's own
// RegisterDefaultCodecs so SDP produced here looks like any other pion peer's.
var videoCodecDefs = map[string]struct {
	mime    string
	pt, rtx webrtc.PayloadType
	fmtp    string
}{
	"VP8": {webrtc.MimeTypeVP8, 96, 97, ""},
	"VP9": {webrtc.MimeTypeVP9, 98, 99, "profile-id=0"},
	"AV1": {webrtc.MimeTypeAV1, 45, 46, ""},
}

var videoFeedback = []webrtc.RTCPFeedback{
	{Type: "goog-remb"}, {Type: "ccm", Parameter: "fir"},
	{Type: "nack"}, {Type: "nack", Parameter: "pli"},
}

// buildMediaEngine registers only the codecs named in a media_engine payload,
// in the order given (which is the order they appear in SDP, i.e. preference):
//
//	{"video_codecs": ["AV1", "VP9", "VP8"], "audio_codecs": ["opus"]}
//
// Each video codec gets its RTX companion. Pion's default interceptors (NACK,
// RTCP reports, stats) are registered too — an API with a MediaEngine but no
// interceptors would never retransmit.
//
// "nack_interval_ms" sets how often missing packets are NACKed (pion's default
// is 100 ms; a receiver without a jitter buffer wants retransmissions sooner).
func buildMediaEngine(cfg map[string]interface{}) (*webrtc.MediaEngine, *interceptor.Registry, error) {
	m := &webrtc.MediaEngine{}
	video, err := stringList(cfg["video_codecs"])
	if err != nil {
		return nil, nil, fmt.Errorf("video_codecs: %w", err)
	}
	for _, name := range video {
		def, ok := videoCodecDefs[strings.ToUpper(name)]
		if !ok {
			return nil, nil, fmt.Errorf("unknown video codec %q", name)
		}
		if err := m.RegisterCodec(webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: def.mime, ClockRate: 90000, SDPFmtpLine: def.fmtp, RTCPFeedback: videoFeedback,
			},
			PayloadType: def.pt,
		}, webrtc.RTPCodecTypeVideo); err != nil {
			return nil, nil, err
		}
		if err := m.RegisterCodec(webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeRTX, ClockRate: 90000, SDPFmtpLine: fmt.Sprintf("apt=%d", def.pt),
			},
			PayloadType: def.rtx,
		}, webrtc.RTPCodecTypeVideo); err != nil {
			return nil, nil, err
		}
	}
	audio, err := stringList(cfg["audio_codecs"])
	if err != nil {
		return nil, nil, fmt.Errorf("audio_codecs: %w", err)
	}
	for _, name := range audio {
		if !strings.EqualFold(name, "opus") {
			return nil, nil, fmt.Errorf("unknown audio codec %q", name)
		}
		if err := m.RegisterCodec(webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;useinbandfec=1",
			},
			PayloadType: 111,
		}, webrtc.RTPCodecTypeAudio); err != nil {
			return nil, nil, err
		}
	}
	var interceptorOpts []webrtc.InterceptorOption
	if ms, ok := toInt(cfg["nack_interval_ms"]); ok {
		if ms <= 0 {
			return nil, nil, fmt.Errorf("nack_interval_ms must be positive")
		}
		interceptorOpts = append(interceptorOpts,
			webrtc.WithNackGeneratorOptions(nack.GeneratorInterval(time.Duration(ms)*time.Millisecond)))
	}
	reg := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptorsWithOptions(m, reg, interceptorOpts...); err != nil {
		return nil, nil, err
	}
	return m, reg, nil
}

func stringList(v interface{}) ([]string, error) {
	if v == nil {
		return nil, nil
	}
	items, ok := v.([]interface{})
	if !ok {
		return nil, fmt.Errorf("must be a list of strings")
	}
	out := make([]string, 0, len(items))
	for _, it := range items {
		s, ok := it.(string)
		if !ok {
			return nil, fmt.Errorf("must be a list of strings")
		}
		out = append(out, s)
	}
	return out, nil
}
