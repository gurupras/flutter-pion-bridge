package pionserver

import (
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
)

// Handler processes incoming messages and returns responses.
type Handler struct {
	registry  *Registry
	sendEvent func(Message) // sends events back to the client
	api       *webrtc.API  // built on init; defaults to the standard API

	// Per-DataChannel send queues.  Each DC gets a dedicated goroutine so that
	// dc:send calls to different connections execute concurrently instead of
	// being serialized by the single WebSocket read loop.
	sendChsMu sync.RWMutex
	sendChs   map[string]chan []byte // dcHandle → send queue
}

// NewHandler creates a new message handler.
func NewHandler(registry *Registry, sendEvent func(Message)) *Handler {
	return &Handler{
		registry:  registry,
		sendEvent: sendEvent,
		api:       webrtc.NewAPI(),
		sendChs:   make(map[string]chan []byte),
	}
}

// startDCSendGoroutine creates a buffered channel for dcHandle and starts a
// dedicated goroutine that drains it by calling dc.Send().  Must be called
// once per DataChannel after it has been registered.
func (h *Handler) startDCSendGoroutine(dc *webrtc.DataChannel, dcHandle string) {
	ch := make(chan []byte, 4096)
	h.sendChsMu.Lock()
	h.sendChs[dcHandle] = ch
	h.sendChsMu.Unlock()

	idx := Trace.DCIdx(dcHandle)

	go func() {
		for data := range ch {
			t0 := time.Now()
			if err := dc.Send(data); err != nil {
				h.sendEvent(Event("event:dc:error", dcHandle, map[string]interface{}{
					"error": err.Error(),
				}))
			}
			atomic.AddInt64(&Trace.DCFrames[idx], 1)
			atomic.AddInt64(&Trace.DCBytes[idx], int64(len(data)))
			atomic.AddInt64(&Trace.DCNs[idx], time.Since(t0).Nanoseconds())
		}
	}()
}

// stopDCSendGoroutine closes the send channel for dcHandle, causing its
// goroutine to exit cleanly.
func (h *Handler) stopDCSendGoroutine(dcHandle string) {
	h.sendChsMu.Lock()
	ch, ok := h.sendChs[dcHandle]
	if ok {
		delete(h.sendChs, dcHandle)
	}
	h.sendChsMu.Unlock()
	if ok {
		close(ch)
	}
}

// HandleMessage routes a message to the appropriate handler.
func (h *Handler) HandleMessage(msg *Message) Message {
	switch msg.Type {
	case "init":
		return h.handleInit(msg)
	case "pc:create":
		return h.handlePCCreate(msg)
	case "pc:offer":
		return h.handlePCOffer(msg)
	case "pc:answer":
		return h.handlePCAnswer(msg)
	case "pc:setLocalDesc":
		return h.handlePCSetLocalDesc(msg)
	case "pc:setRemoteDesc":
		return h.handlePCSetRemoteDesc(msg)
	case "pc:addIce":
		return h.handlePCAddIce(msg)
	case "pc:close":
		return h.handlePCClose(msg)
	case "pc:createDc":
		return h.handlePCCreateDc(msg)
	case "dc:send":
		return h.handleDCSend(msg)
	case "dc:setBufferedAmountLowThreshold":
		return h.handleDCSetBufferedAmountLowThreshold(msg)
	case "dc:close":
		return h.handleDCClose(msg)
	case "resource:delete":
		return h.handleResourceDelete(msg)
	default:
		return ErrorResponse(msg.ID, "INVALID_REQUEST", fmt.Sprintf("unknown message type: %s", msg.Type), false, "")
	}
}

func (h *Handler) handleInit(msg *Message) Message {
	se := webrtc.SettingEngine{}
	if cfg, ok := msg.Data["settings_engine"].(map[string]interface{}); ok {
		if err := applySettingsEngine(&se, cfg); err != nil {
			return ErrorResponse(msg.ID, "INVALID_REQUEST", err.Error(), false, "")
		}
	}
	h.api = webrtc.NewAPI(webrtc.WithSettingEngine(se))
	return AckResponse("init", msg.ID, "", map[string]interface{}{
		"version": "1.0.0",
	})
}

func (h *Handler) handlePCCreate(msg *Message) Message {
	config := webrtc.Configuration{}

	if servers, ok := msg.Data["ice_servers"]; ok {
		if serverList, ok := servers.([]interface{}); ok {
			for _, s := range serverList {
				srv, ok := s.(map[string]interface{})
				if !ok {
					continue
				}
				iceServer := webrtc.ICEServer{}
				if urls, ok := srv["urls"]; ok {
					switch v := urls.(type) {
					case []interface{}:
						for _, u := range v {
							if str, ok := u.(string); ok {
								iceServer.URLs = append(iceServer.URLs, str)
							}
						}
					case string:
						iceServer.URLs = []string{v}
					}
				}
				if username, ok := srv["username"].(string); ok {
					iceServer.Username = username
				}
				if credential, ok := srv["credential"].(string); ok {
					iceServer.Credential = credential
				}
				config.ICEServers = append(config.ICEServers, iceServer)
			}
		}
	}

	if bp, ok := msg.Data["bundle_policy"].(string); ok {
		switch bp {
		case "balanced":
			config.BundlePolicy = webrtc.BundlePolicyBalanced
		case "max-compat":
			config.BundlePolicy = webrtc.BundlePolicyMaxCompat
		case "max-bundle":
			config.BundlePolicy = webrtc.BundlePolicyMaxBundle
		}
	}

	if rmp, ok := msg.Data["rtcp_mux_policy"].(string); ok {
		switch rmp {
		case "negotiate":
			config.RTCPMuxPolicy = webrtc.RTCPMuxPolicyNegotiate
		case "require":
			config.RTCPMuxPolicy = webrtc.RTCPMuxPolicyRequire
		}
	}

	pc, err := h.api.NewPeerConnection(config)
	if err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, "")
	}

	handle := h.registry.Register(pc)
	h.setupPCCallbacks(pc, handle)

	return AckResponse("pc:create", msg.ID, handle, map[string]interface{}{
		"handle": handle,
		"state":  "new",
	})
}

func (h *Handler) setupPCCallbacks(pc *webrtc.PeerConnection, handle string) {
	pc.OnICECandidate(func(candidate *webrtc.ICECandidate) {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnICECandidate callback for %s: %v", handle, r)
			}
		}()
		if candidate == nil {
			// ICE gathering complete
			h.sendEvent(Event("event:iceGatheringComplete", handle, map[string]interface{}{}))
			return
		}
		init := candidate.ToJSON()
		data := map[string]interface{}{
			"type":            "iceCandidate",
			"candidate":       init.Candidate,
			"sdp_mid":         "",
			"sdp_mline_index": 0,
		}
		if init.SDPMid != nil {
			data["sdp_mid"] = *init.SDPMid
		}
		if init.SDPMLineIndex != nil {
			data["sdp_mline_index"] = *init.SDPMLineIndex
		}
		h.sendEvent(Event("event:iceCandidate", handle, data))
	})

	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnConnectionStateChange callback for %s: %v", handle, r)
			}
		}()
		h.sendEvent(Event("event:connectionStateChange", handle, map[string]interface{}{
			"type":  "connectionStateChange",
			"state": state.String(),
		}))
	})

	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnDataChannel callback for %s: %v", handle, r)
			}
		}()
		dcHandle := h.registry.RegisterChild(dc, handle)
		h.setupDCCallbacks(dc, dcHandle)
		h.startDCSendGoroutine(dc, dcHandle)
		h.sendEvent(Event("event:dataChannel", handle, map[string]interface{}{
			"type":      "dataChannel",
			"dc_handle": dcHandle,
			"label":     dc.Label(),
			"ordered":   dc.Ordered(),
		}))
	})
}

func (h *Handler) setupDCCallbacks(dc *webrtc.DataChannel, dcHandle string) {
	dc.OnOpen(func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnOpen callback for %s: %v", dcHandle, r)
			}
		}()
		h.sendEvent(Event("event:dataChannelOpen", dcHandle, map[string]interface{}{
			"type": "open",
		}))
	})

	dc.OnClose(func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnClose callback for %s: %v", dcHandle, r)
			}
		}()
		h.sendEvent(Event("event:dataChannelClose", dcHandle, map[string]interface{}{
			"type": "close",
		}))
	})

	dc.OnMessage(func(dcMsg webrtc.DataChannelMessage) {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnMessage callback for %s: %v", dcHandle, r)
			}
		}()
		data := map[string]interface{}{
			"type":      "message",
			"is_binary": dcMsg.IsString == false,
		}
		if dcMsg.IsString {
			data["data"] = string(dcMsg.Data)
			data["is_binary"] = false
		} else {
			data["data"] = dcMsg.Data
			data["is_binary"] = true
		}
		h.sendEvent(Event("event:dataChannelMessage", dcHandle, data))
	})
}

func (h *Handler) lookupPC(msg *Message) (*webrtc.PeerConnection, Message, bool) {
	if msg.Handle == "" {
		return nil, ErrorResponse(msg.ID, "INVALID_REQUEST", "missing handle", false, ""), false
	}
	res, ok := h.registry.Lookup(msg.Handle)
	if !ok {
		return nil, ErrorResponse(msg.ID, "NOT_FOUND", "handle not found: "+msg.Handle, false, msg.Handle), false
	}
	pc, ok := res.(*webrtc.PeerConnection)
	if !ok {
		return nil, ErrorResponse(msg.ID, "INVALID_REQUEST", "handle is not a PeerConnection", false, msg.Handle), false
	}
	return pc, Message{}, true
}

func (h *Handler) lookupDC(msg *Message) (*webrtc.DataChannel, Message, bool) {
	if msg.Handle == "" {
		return nil, ErrorResponse(msg.ID, "INVALID_REQUEST", "missing handle", false, ""), false
	}
	res, ok := h.registry.Lookup(msg.Handle)
	if !ok {
		return nil, ErrorResponse(msg.ID, "NOT_FOUND", "handle not found: "+msg.Handle, false, msg.Handle), false
	}
	dc, ok := res.(*webrtc.DataChannel)
	if !ok {
		return nil, ErrorResponse(msg.ID, "INVALID_REQUEST", "handle is not a DataChannel", false, msg.Handle), false
	}
	return dc, Message{}, true
}

func (h *Handler) handlePCOffer(msg *Message) Message {
	pc, errMsg, ok := h.lookupPC(msg)
	if !ok {
		return errMsg
	}

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	return AckResponse("pc:offer", msg.ID, msg.Handle, map[string]interface{}{
		"sdp": offer.SDP,
	})
}

func (h *Handler) handlePCAnswer(msg *Message) Message {
	pc, errMsg, ok := h.lookupPC(msg)
	if !ok {
		return errMsg
	}

	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	return AckResponse("pc:answer", msg.ID, msg.Handle, map[string]interface{}{
		"sdp": answer.SDP,
	})
}

func (h *Handler) handlePCSetLocalDesc(msg *Message) Message {
	pc, errMsg, ok := h.lookupPC(msg)
	if !ok {
		return errMsg
	}

	sdp, _ := msg.Data["sdp"].(string)
	sdpType, _ := msg.Data["type"].(string)
	if sdp == "" || sdpType == "" {
		return ErrorResponse(msg.ID, "INVALID_REQUEST", "missing sdp or type", false, msg.Handle)
	}

	desc := webrtc.SessionDescription{
		SDP:  sdp,
		Type: parseSdpType(sdpType),
	}

	if err := pc.SetLocalDescription(desc); err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	return AckResponse("pc:setLocalDesc", msg.ID, msg.Handle, map[string]interface{}{
		"state": pc.SignalingState().String(),
	})
}

func (h *Handler) handlePCSetRemoteDesc(msg *Message) Message {
	pc, errMsg, ok := h.lookupPC(msg)
	if !ok {
		return errMsg
	}

	sdp, _ := msg.Data["sdp"].(string)
	sdpType, _ := msg.Data["type"].(string)
	if sdp == "" || sdpType == "" {
		return ErrorResponse(msg.ID, "INVALID_REQUEST", "missing sdp or type", false, msg.Handle)
	}

	desc := webrtc.SessionDescription{
		SDP:  sdp,
		Type: parseSdpType(sdpType),
	}

	if err := pc.SetRemoteDescription(desc); err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	return AckResponse("pc:setRemoteDesc", msg.ID, msg.Handle, map[string]interface{}{
		"state": pc.SignalingState().String(),
	})
}

func (h *Handler) handlePCAddIce(msg *Message) Message {
	pc, errMsg, ok := h.lookupPC(msg)
	if !ok {
		return errMsg
	}

	candidateStr, _ := msg.Data["candidate"].(string)
	if candidateStr == "" {
		return ErrorResponse(msg.ID, "INVALID_REQUEST", "missing candidate", false, msg.Handle)
	}

	sdpMid, _ := msg.Data["sdp_mid"].(string)
	var sdpMLineIndex *uint16
	if idx, ok := toUint16(msg.Data["sdp_mline_index"]); ok {
		sdpMLineIndex = &idx
	}

	init := webrtc.ICECandidateInit{
		Candidate:     candidateStr,
		SDPMid:        &sdpMid,
		SDPMLineIndex: sdpMLineIndex,
	}

	if err := pc.AddICECandidate(init); err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	return AckResponse("pc:addIce", msg.ID, msg.Handle, map[string]interface{}{})
}

func (h *Handler) handlePCClose(msg *Message) Message {
	pc, errMsg, ok := h.lookupPC(msg)
	if !ok {
		return errMsg
	}

	if err := pc.Close(); err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	return AckResponse("pc:close", msg.ID, msg.Handle, map[string]interface{}{})
}

func (h *Handler) handlePCCreateDc(msg *Message) Message {
	pc, errMsg, ok := h.lookupPC(msg)
	if !ok {
		return errMsg
	}

	label, _ := msg.Data["label"].(string)
	if label == "" {
		return ErrorResponse(msg.ID, "INVALID_REQUEST", "missing label", false, msg.Handle)
	}

	dcInit := &webrtc.DataChannelInit{}
	if opts, ok := msg.Data["options"].(map[string]interface{}); ok {
		if ordered, ok := opts["ordered"].(bool); ok {
			dcInit.Ordered = &ordered
		}
		if mr, ok := toUint16(opts["max_retransmits"]); ok {
			dcInit.MaxRetransmits = &mr
		}
		if mpl, ok := toUint16(opts["max_packet_lifetime_ms"]); ok {
			dcInit.MaxPacketLifeTime = &mpl
		}
	}

	dc, err := pc.CreateDataChannel(label, dcInit)
	if err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	dcHandle := h.registry.RegisterChild(dc, msg.Handle)
	h.setupDCCallbacks(dc, dcHandle)
	h.startDCSendGoroutine(dc, dcHandle)

	return AckResponse("pc:createDc", msg.ID, msg.Handle, map[string]interface{}{
		"dc_handle": dcHandle,
		"label":     dc.Label(),
		"state":     "connecting",
	})
}

func (h *Handler) handleDCSend(msg *Message) Message {
	// Route to the per-DC goroutine so that sends to different connections
	// execute concurrently rather than being serialized by the read loop.
	h.sendChsMu.RLock()
	ch, ok := h.sendChs[msg.Handle]
	h.sendChsMu.RUnlock()

	if !ok {
		h.sendEvent(Event("event:dc:error", msg.Handle, map[string]interface{}{
			"error": "dc:send on unknown handle: " + msg.Handle,
		}))
		return Message{}
	}

	switch payload := msg.Data["data"].(type) {
	case []byte:
		// Copy before returning msg to the pool.
		buf := make([]byte, len(payload))
		copy(buf, payload)
		// Record channel depth before push so we can see if sends are backing up.
		h.sendChsMu.RLock()
		idx := Trace.DCIdx(msg.Handle)
		h.sendChsMu.RUnlock()
		depth := int64(len(ch))
		if cur := atomic.LoadInt64(&Trace.DCQDepth[idx]); depth > cur {
			atomic.StoreInt64(&Trace.DCQDepth[idx], depth) // track peak per interval
		}
		ch <- buf // block if channel full — correct back-pressure, no data loss
	case string:
		// Text sends are rare (control channel); handle inline via a separate path.
		dc, errMsg, ok2 := h.lookupDC(msg)
		if !ok2 {
			h.sendEvent(Event("event:dc:error", msg.Handle, map[string]interface{}{
				"error": errMsg.Data["message"],
			}))
			return Message{}
		}
		if err := dc.SendText(payload); err != nil {
			h.sendEvent(Event("event:dc:error", msg.Handle, map[string]interface{}{
				"error": err.Error(),
			}))
		}
	default:
		h.sendEvent(Event("event:dc:error", msg.Handle, map[string]interface{}{
			"error": "data must be string or binary",
		}))
	}
	return Message{}
}

func (h *Handler) handleDCSetBufferedAmountLowThreshold(msg *Message) Message {
	dc, errMsg, ok := h.lookupDC(msg)
	if !ok {
		return errMsg
	}

	threshold, ok := toUint64(msg.Data["threshold"])
	if !ok {
		return ErrorResponse(msg.ID, "INVALID_REQUEST", "missing or invalid threshold", false, msg.Handle)
	}

	dcHandle := msg.Handle
	dc.SetBufferedAmountLowThreshold(threshold)
	dc.OnBufferedAmountLow(func() {
		h.sendEvent(Event("event:bufferedAmountLow", dcHandle, map[string]interface{}{}))
	})

	return AckResponse("dc:setBufferedAmountLowThreshold", msg.ID, msg.Handle, map[string]interface{}{})
}

func (h *Handler) handleDCClose(msg *Message) Message {
	dc, errMsg, ok := h.lookupDC(msg)
	if !ok {
		return errMsg
	}

	h.stopDCSendGoroutine(msg.Handle)

	if err := dc.Close(); err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, msg.Handle)
	}

	return AckResponse("dc:close", msg.ID, msg.Handle, map[string]interface{}{})
}

func (h *Handler) handleResourceDelete(msg *Message) Message {
	if msg.Handle == "" {
		return ErrorResponse(msg.ID, "INVALID_REQUEST", "missing handle", false, "")
	}

	if err := h.registry.Delete(msg.Handle); err != nil {
		return ErrorResponse(msg.ID, "NOT_FOUND", err.Error(), false, msg.Handle)
	}

	return AckResponse("resource:delete", msg.ID, msg.Handle, map[string]interface{}{})
}

// Helper functions

func parseSdpType(t string) webrtc.SDPType {
	switch t {
	case "offer":
		return webrtc.SDPTypeOffer
	case "pranswer":
		return webrtc.SDPTypePranswer
	case "answer":
		return webrtc.SDPTypeAnswer
	case "rollback":
		return webrtc.SDPTypeRollback
	default:
		return webrtc.SDPTypeOffer
	}
}

func toUint64(v interface{}) (uint64, bool) {
	switch n := v.(type) {
	case int:
		return uint64(n), true
	case int8:
		return uint64(n), true
	case int16:
		return uint64(n), true
	case int32:
		return uint64(n), true
	case int64:
		return uint64(n), true
	case uint:
		return uint64(n), true
	case uint8:
		return uint64(n), true
	case uint16:
		return uint64(n), true
	case uint32:
		return uint64(n), true
	case uint64:
		return n, true
	case float32:
		return uint64(n), true
	case float64:
		return uint64(n), true
	default:
		return 0, false
	}
}

func toUint16(v interface{}) (uint16, bool) {
	switch n := v.(type) {
	case int:
		return uint16(n), true
	case int8:
		return uint16(n), true
	case int16:
		return uint16(n), true
	case int32:
		return uint16(n), true
	case int64:
		return uint16(n), true
	case uint:
		return uint16(n), true
	case uint8:
		return uint16(n), true
	case uint16:
		return n, true
	case uint32:
		return uint16(n), true
	case uint64:
		return uint16(n), true
	case float32:
		return uint16(n), true
	case float64:
		return uint16(n), true
	default:
		return 0, false
	}
}
