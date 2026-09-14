package pionserver

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/datachannel"
	"github.com/pion/webrtc/v4"
)

// apiProfile is one webrtc.API plus the settings the bridge itself has to act
// on. A session has a default profile from `init`, and pc:create may carry its
// own settings_engine — pion applies a SettingEngine per API, so a session can
// hold several (e.g. one PeerConnection with detached channels for bulk
// transfer and another without for latency-sensitive traffic).
type apiProfile struct {
	api *webrtc.API
	// detach mirrors SettingEngine.DetachDataChannels: every DataChannel on
	// this API is detached on open, read by a bridge-owned loop and written
	// through the detached ReadWriteCloser (which is what makes
	// enable_data_channel_block_write take effect).
	detach bool
	// maxMessageSize bounds the detached read buffer (sctp_max_message_size).
	maxMessageSize int
}

// Handler processes incoming messages and returns responses.
type Handler struct {
	registry  *Registry
	sendEvent func(Message) // sends events back to the client
	dcConfig  DCConfig      // tunables applied to every new DataChannel

	mu sync.Mutex
	// defaultProfile comes from `init` and is used unless pc:create overrides it.
	defaultProfile *apiProfile
	// profiles caches one API per distinct pc:create settings_engine payload.
	profiles map[string]*apiProfile
	// pcProfiles maps a PeerConnection handle to the profile it was created
	// with, so its DataChannels use the same settings.
	pcProfiles map[string]*apiProfile
}

// NewHandler creates a new message handler with default DC configuration.
// Pass a custom [DCConfig] via [NewHandlerWithConfig] to override defaults.
func NewHandler(registry *Registry, sendEvent func(Message)) *Handler {
	return NewHandlerWithConfig(registry, sendEvent, DefaultDCConfig)
}

// NewHandlerWithConfig creates a new message handler with the provided DC
// configuration applied to every DataChannel created through this Handler.
//
// Outbound events count as TTL activity: a receive-only DataChannel produces
// no inbound RPCs, so without the Touch here the cleanup sweeper would reap
// a healthy in-use connection.
func NewHandlerWithConfig(registry *Registry, sendEvent func(Message), cfg DCConfig) *Handler {
	return &Handler{
		registry: registry,
		sendEvent: func(m Message) {
			if m.Handle != "" {
				registry.Touch(m.Handle)
			}
			sendEvent(m)
		},
		defaultProfile: &apiProfile{api: webrtc.NewAPI()},
		profiles:       map[string]*apiProfile{},
		pcProfiles:     map[string]*apiProfile{},
		dcConfig:       cfg,
	}
}

// buildProfile turns a settings_engine payload into an API and the settings the
// bridge acts on itself.
func buildProfile(cfg map[string]interface{}) (*apiProfile, error) {
	se := webrtc.SettingEngine{}
	if cfg != nil {
		if err := applySettingsEngine(&se, cfg); err != nil {
			return nil, err
		}
	}
	p := &apiProfile{api: webrtc.NewAPI(webrtc.WithSettingEngine(se))}
	if cfg != nil {
		p.detach, _ = cfg["detach_data_channels"].(bool)
		if v, ok := toInt(cfg["sctp_max_message_size"]); ok {
			p.maxMessageSize = int(v)
		}
	}
	return p, nil
}

// profileFor returns the cached API for this settings payload, building it on
// first use. Identical payloads share one API, so repeated pc:create calls with
// the same settings do not pile up APIs.
func (h *Handler) profileFor(cfg map[string]interface{}) (*apiProfile, error) {
	key, err := json.Marshal(cfg) // encoding/json sorts map keys
	if err != nil {
		return nil, err
	}
	h.mu.Lock()
	if p, ok := h.profiles[string(key)]; ok {
		h.mu.Unlock()

		return p, nil
	}
	h.mu.Unlock()

	p, err := buildProfile(cfg)
	if err != nil {
		return nil, err
	}
	h.mu.Lock()
	if existing, ok := h.profiles[string(key)]; ok { // lost a race; keep one API
		p = existing
	} else {
		h.profiles[string(key)] = p
	}
	h.mu.Unlock()

	return p, nil
}

func (h *Handler) setPCProfile(pcHandle string, p *apiProfile) {
	h.mu.Lock()
	h.pcProfiles[pcHandle] = p
	h.mu.Unlock()
}

func (h *Handler) forgetPCProfile(pcHandle string) {
	h.mu.Lock()
	delete(h.pcProfiles, pcHandle)
	h.mu.Unlock()
}

// pcProfile returns the profile a PeerConnection was created with (the session
// default for connections created before per-PC settings existed).
func (h *Handler) pcProfile(pcHandle string) *apiProfile {
	h.mu.Lock()
	defer h.mu.Unlock()
	if p, ok := h.pcProfiles[pcHandle]; ok {
		return p
	}

	return h.defaultProfile
}

// startDCSendGoroutine allocates per-DC send state, registers it on the
// global registry, hooks pion's OnBufferedAmountLow callback unconditionally,
// and starts the dedicated goroutine that turns each `dc:send` request into
// an ack-on-drain RPC.  The ack only fires after dc.Send has returned AND
// pion's native send buffer has fallen at or below the configured threshold
// (default 512 KB).  This is the single backpressure point at this layer:
// callers awaiting the ack get true end-of-buffer semantics rather than
// fire-and-forget.
//
// Storing state on the registry (rather than the Handler) means dc:send works
// from any WebSocket connection, not just the one that created the DC —
// essential for cross-isolate use where the creating connection may already
// be closed by the time another isolate sends.
func (h *Handler) startDCSendGoroutine(dc *webrtc.DataChannel, dcHandle string, profile *apiProfile) {
	state := newDCSendState(h.dcConfig, profile.detach)
	if !h.registry.RegisterDCSendState(dcHandle, state) {
		// Already registered (shouldn't happen — RegisterChild gives unique
		// handles).
		log.Printf("warning: duplicate DC send goroutine registration for %s", dcHandle)
		return
	}

	// Hook OnBufferedAmountLow unconditionally so the sender goroutine wakes
	// when pion's buffer drains.  We also emit event:bufferedAmountLow for
	// consumers that monitor buffer state for telemetry.
	dc.SetBufferedAmountLowThreshold(state.threshold)
	dc.OnBufferedAmountLow(func() {
		if LifecycleLogEnabled() {
			lifeLogf("OnBufferedAmountLow dc=%s buffered=%d threshold=%d", dcHandle, dc.BufferedAmount(), state.threshold)
		}
		state.signalLow()
		h.sendEvent(Event("event:bufferedAmountLow", dcHandle, map[string]interface{}{}))
	})

	go func() {
		for {
			select {
			case <-state.done:
				return
			case w, ok := <-state.work:
				if !ok {
					return
				}
				h.runDCSend(dc, dcHandle, state, w)
			}
		}
	}()
}

// runDCSend issues a single dc.Send/dc.SendText, waits for the buffered
// amount to drop below the threshold, and emits the ack/error.  The ack goes
// through w.sendEvent — the connection that issued this dc:send — never the
// (possibly closed) connection that created the DC.
func (h *Handler) runDCSend(
	dc *webrtc.DataChannel,
	dcHandle string,
	state *DCSendState,
	w dcSendWork,
) {
	sendEvent := w.sendEvent
	if LifecycleLogEnabled() {
		lifeLogf("dc.Send pre  dc=%s msgID=%d len=%d buffered=%d", dcHandle, w.msgID, len(w.data), dc.BufferedAmount())
	}
	var sendErr error
	if Trace.Enabled() {
		// Resolve the trace slot lazily so no slot is allocated (and leaked)
		// for channels created while tracing is off.
		idx := Trace.DCIdx(dcHandle)
		t0 := time.Now()
		sendErr = h.doSend(dc, state, w)
		atomic.AddInt64(&Trace.DCFrames[idx], 1)
		atomic.AddInt64(&Trace.DCBytes[idx], int64(len(w.data)))
		atomic.AddInt64(&Trace.DCNs[idx], time.Since(t0).Nanoseconds())
	} else {
		sendErr = h.doSend(dc, state, w)
	}
	if LifecycleLogEnabled() {
		lifeLogf("dc.Send post dc=%s msgID=%d err=%v buffered=%d", dcHandle, w.msgID, sendErr, dc.BufferedAmount())
	}

	if sendErr != nil {
		sendEvent(ErrorResponse(w.msgID, "DC_SEND_ERROR", sendErr.Error(), false, dcHandle))
		sendEvent(Event("event:dc:error", dcHandle, map[string]interface{}{
			"error": sendErr.Error(),
		}))
		return
	}

	if w.awaitDrain {
		// Block the ack until pion has drained below the low-water mark.  If
		// the DC is closed mid-wait we still ack with an error so the
		// caller's Future doesn't hang.
		if !state.waitForBuffer(dc) {
			if LifecycleLogEnabled() {
				lifeLogf("dc.Send ack-skip (DC_CLOSED) dc=%s msgID=%d", dcHandle, w.msgID)
			}
			sendEvent(ErrorResponse(w.msgID, "DC_CLOSED", "data channel closed during send", false, dcHandle))
			return
		}
	}

	if LifecycleLogEnabled() {
		lifeLogf("dc.Send ack-emit dc=%s msgID=%d awaitDrain=%v", dcHandle, w.msgID, w.awaitDrain)
	}
	sendEvent(AckResponse("dc:send", w.msgID, dcHandle, nil))
}

// errDetachedNotOpen is returned for a send on a detached channel that has not
// opened yet (pion's own Send reports the same condition for attached ones).
var errDetachedNotOpen = errors.New("data channel is not open")

// doSend dispatches one work unit to the right pion send call. Detached
// channels write through the detached ReadWriteCloser, which blocks while the
// SCTP send buffer is full when enable_data_channel_block_write is set.
func (h *Handler) doSend(dc *webrtc.DataChannel, state *DCSendState, w dcSendWork) error {
	if state.detach {
		raw := state.detached()
		if raw == nil {
			return errDetachedNotOpen
		}
		var err error
		if w.isText {
			_, err = raw.WriteDataChannel([]byte(w.text), true)
		} else {
			_, err = raw.WriteDataChannel(w.data, false)
		}
		return err
	}
	if w.isText {
		return dc.SendText(w.text)
	}
	return dc.Send(w.data)
}

// stopDCSendGoroutine removes the send state for dcHandle and closes it,
// causing the goroutine to exit cleanly.  Safe to call from any handler —
// the state lives on the registry, not the handler.
func (h *Handler) stopDCSendGoroutine(dcHandle string) {
	if state, ok := h.registry.RemoveDCSendState(dcHandle); ok {
		state.closeState()
	}
	Trace.ReleaseDC(dcHandle)
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

// cfgOrNil narrows a decoded settings_engine value to a map, or nil.
func cfgOrNil(v interface{}) map[string]interface{} {
	cfg, _ := v.(map[string]interface{})

	return cfg
}

func (h *Handler) handleInit(msg *Message) Message {
	if cfg, ok := msg.Data["settings_engine"].(map[string]interface{}); ok {
		if v, _ := cfg["enable_tracing"].(bool); v {
			StartTracing("bridge")
		}
	}
	if dc, ok := msg.Data["dc_config"].(map[string]interface{}); ok {
		if v, ok := toUint64(dc["buffered_amount_low_threshold"]); ok {
			h.dcConfig.BufferedAmountLowThreshold = v
		}
		if v, ok := toInt(dc["send_queue_depth"]); ok && v >= 1 {
			h.dcConfig.SendQueueDepth = int(v)
		}
	}
	profile, err := buildProfile(cfgOrNil(msg.Data["settings_engine"]))
	if err != nil {
		return ErrorResponse(msg.ID, "INVALID_REQUEST", err.Error(), false, "")
	}
	h.mu.Lock()
	h.defaultProfile = profile
	h.mu.Unlock()
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

	// "relay" forces ICE to gather and use ONLY relay (TURN) candidates,
	// discarding host + server-reflexive ones. Used to prove/force the TURN
	// data path (e.g. two NAT-permissive emulators whose srflx candidates would
	// otherwise win). Defaults to "all" (unset) — normal host/srflx/relay.
	if itp, ok := msg.Data["ice_transport_policy"].(string); ok {
		switch itp {
		case "relay":
			config.ICETransportPolicy = webrtc.ICETransportPolicyRelay
		case "all":
			config.ICETransportPolicy = webrtc.ICETransportPolicyAll
		}
	}

	profile := h.defaultProfile
	if cfg := cfgOrNil(msg.Data["settings_engine"]); cfg != nil {
		var perr error
		if profile, perr = h.profileFor(cfg); perr != nil {
			return ErrorResponse(msg.ID, "INVALID_REQUEST", perr.Error(), false, "")
		}
	}
	pc, err := profile.api.NewPeerConnection(config)
	if err != nil {
		return ErrorResponse(msg.ID, "INTERNAL_ERROR", err.Error(), false, "")
	}

	handle := h.registry.Register(pc)
	h.setPCProfile(handle, profile) // before callbacks: a remote DataChannel needs it
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
		profile := h.pcProfile(handle)
		dcHandle := h.registry.RegisterChild(dc, handle)
		h.startDCSendGoroutine(dc, dcHandle, profile) // before callbacks: a detached OnOpen needs the send state
		h.setupDCCallbacks(dc, dcHandle, profile)
		h.sendEvent(Event("event:dataChannel", handle, map[string]interface{}{
			"type":      "dataChannel",
			"dc_handle": dcHandle,
			"label":     dc.Label(),
			"ordered":   dc.Ordered(),
		}))
	})
}

func (h *Handler) setupDCCallbacks(dc *webrtc.DataChannel, dcHandle string, profile *apiProfile) {
	// A detached channel is not in pion's close notifications (pion drops it
	// from the transport on Detach and runs no read loop), so the bridge's read
	// loop reports the close itself; once guards against a duplicate.
	var closeOnce sync.Once
	emitClose := func() {
		closeOnce.Do(func() {
			h.sendEvent(Event("event:dataChannelClose", dcHandle, map[string]interface{}{
				"type": "close",
			}))
		})
	}

	dc.OnOpen(func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnOpen callback for %s: %v", dcHandle, r)
			}
		}()
		if profile.detach {
			// Pion requires Detach inside OnOpen when detaching is enabled.
			raw, err := dc.Detach()
			if err != nil {
				h.sendEvent(Event("event:dc:error", dcHandle, map[string]interface{}{"error": "detach: " + err.Error()}))
				return
			}
			if state, ok := h.registry.LookupDCSendState(dcHandle); ok {
				state.setDetached(raw)
			}
			h.sendEvent(Event("event:dataChannelOpen", dcHandle, map[string]interface{}{
				"type": "open",
			}))
			go h.readDetached(raw, dcHandle, profile.maxMessageSize, emitClose)
			return
		}
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
		emitClose()
	})

	if profile.detach {
		return // messages are read by readDetached, OnMessage never fires
	}

	dc.OnMessage(func(dcMsg webrtc.DataChannelMessage) {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in OnMessage callback for %s: %v", dcHandle, r)
			}
		}()
		if LifecycleLogEnabled() {
			lifeLogf("OnMessage dc=%s len=%d isString=%v", dcHandle, len(dcMsg.Data), dcMsg.IsString)
		}
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

// readDetached is the read loop for a detached DataChannel: it forwards every
// message as the same event:dataChannelMessage an attached channel produces,
// grows its buffer for large messages up to sctp_max_message_size, and reports
// the close when the channel ends.
func (h *Handler) readDetached(raw datachannel.ReadWriteCloser, dcHandle string, maxMessageSize int, emitClose func()) {
	defer emitClose()
	limit := maxMessageSize
	if limit <= 0 {
		limit = 1073741823 // pion's default SCTP max message size; the buffer grows on demand
	}
	buf := make([]byte, min(limit, 65536))
	for {
		n, isString, err := raw.ReadDataChannel(buf)
		if errors.Is(err, io.ErrShortBuffer) && len(buf) < limit {
			buf = make([]byte, min(limit, 2*len(buf)))
			continue // pion keeps the message queued on a short buffer
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && LifecycleLogEnabled() {
				lifeLogf("detached read dc=%s err=%v", dcHandle, err)
			}
			return
		}
		data := map[string]interface{}{"type": "message", "is_binary": !isString}
		if isString {
			data["data"] = string(buf[:n])
		} else {
			data["data"] = append([]byte(nil), buf[:n]...)
		}
		h.sendEvent(Event("event:dataChannelMessage", dcHandle, data))
	}
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

	// Only set SDPMid/SDPMLineIndex when the client actually provided them —
	// a non-nil pointer to "" is not the same as absent and can make pion
	// mis-associate the candidate.
	var sdpMid *string
	if v, ok := msg.Data["sdp_mid"].(string); ok {
		sdpMid = &v
	}
	var sdpMLineIndex *uint16
	if idx, ok := toUint16(msg.Data["sdp_mline_index"]); ok {
		sdpMLineIndex = &idx
	}

	init := webrtc.ICECandidateInit{
		Candidate:     candidateStr,
		SDPMid:        sdpMid,
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

	h.forgetPCProfile(msg.Handle)
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
	profile := h.pcProfile(msg.Handle)
	h.startDCSendGoroutine(dc, dcHandle, profile) // before callbacks: a detached OnOpen needs the send state
	h.setupDCCallbacks(dc, dcHandle, profile)

	return AckResponse("pc:createDc", msg.ID, msg.Handle, map[string]interface{}{
		"dc_handle": dcHandle,
		"label":     dc.Label(),
		"state":     "connecting",
	})
}

func (h *Handler) handleDCSend(msg *Message) Message {
	// Both text and binary sends are enqueued onto the per-DC goroutine so a
	// single FIFO covers the whole channel — a text frame issued after queued
	// binary frames must not overtake them (it used to, when text ran inline
	// in the read loop). The ack is emitted asynchronously by the goroutine.
	state, ok := h.registry.LookupDCSendState(msg.Handle)
	if !ok {
		// No registered state — DC handle is unknown (or already torn down).
		// Return a typed error so the Dart-side Future rejects cleanly.
		return ErrorResponse(msg.ID, "NOT_FOUND", "dc:send on unknown handle: "+msg.Handle, false, msg.Handle)
	}

	var work dcSendWork
	switch payload := msg.Data["data"].(type) {
	case []byte:
		// Safe to hand off without copying: the message pool only recycles
		// the Message struct and its map (putMessage deletes keys, never
		// touches values), and the payload slice itself is a fresh
		// allocation unique to this message — gorilla's ReadMessage returns
		// a new frame buffer and msgpack decodes bin into a newly allocated
		// slice. Copying here would add a second full pass over every
		// uploaded chunk (~64 KB memcpy + GC churn per send).
		awaitDrain := true
		if v, ok2 := msg.Data["await_drain"].(bool); ok2 {
			awaitDrain = v
		}
		work = dcSendWork{data: payload, msgID: msg.ID, handle: msg.Handle, awaitDrain: awaitDrain}
	case string:
		// Text is control-channel traffic: ack as soon as SendText returns,
		// no buffered-amount-low wait (matches the previous inline semantics).
		work = dcSendWork{text: payload, isText: true, msgID: msg.ID, handle: msg.Handle, awaitDrain: false}
	default:
		return ErrorResponse(msg.ID, "INVALID_REQUEST", "data must be string or binary", false, msg.Handle)
	}
	// Route the ack/error to THIS connection — the one issuing the send.
	work.sendEvent = h.sendEvent

	if Trace.Enabled() {
		idx := Trace.DCIdx(msg.Handle)
		depth := int64(len(state.work))
		if cur := atomic.LoadInt64(&Trace.DCQDepth[idx]); depth > cur {
			atomic.StoreInt64(&Trace.DCQDepth[idx], depth)
		}
	}
	// Enqueue synchronously so that back-to-back dc:send calls on the
	// same DC reach state.work in WebSocket arrival order.  Cross-DC
	// isolation is preserved because each DC has its own work channel;
	// the configurable queue depth + Dart-side ack pacing keeps the
	// read-loop block window negligible under normal load.
	if LifecycleLogEnabled() {
		lifeLogf("dc:send enqueue dc=%s msgID=%d len=%d isText=%v workQ=%d", msg.Handle, msg.ID, len(work.data), work.isText, len(state.work))
	}
	select {
	case state.work <- work:
		// The state may have closed (and closeState's drain already finished)
		// between our enqueue and now — a `select` with both cases ready picks
		// randomly, so enqueue can succeed after `done` is closed. If so,
		// reclaim one queued item and fail it: it is ours or an equivalent
		// abandoned one, and channel receives are exclusive so nothing is
		// double-answered. If the drain (or the sender) already consumed it,
		// the inner receive misses and the item was answered elsewhere.
		select {
		case <-state.done:
			select {
			case w := <-state.work:
				if w.sendEvent != nil {
					w.sendEvent(ErrorResponse(w.msgID, "DC_CLOSED", "data channel closed before send", false, w.handle))
				}
			default:
			}
		default:
		}
	case <-state.done:
		if LifecycleLogEnabled() {
			lifeLogf("dc:send enqueue-fail (closed) dc=%s msgID=%d", msg.Handle, msg.ID)
		}
		h.sendEvent(ErrorResponse(msg.ID, "DC_CLOSED", "data channel closed before send", false, msg.Handle))
	}
	// No synchronous response — ack is emitted by the per-DC goroutine
	// after the send (and, for awaitDrain, buffered-amount-low).
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

	// Update the per-DC sender state's threshold so the ack-on-drain wait
	// uses the new value.  OnBufferedAmountLow was hooked once at DC create
	// time (see startDCSendGoroutine); we don't re-register it here.
	dc.SetBufferedAmountLowThreshold(threshold)
	if state, ok := h.registry.LookupDCSendState(msg.Handle); ok {
		state.setThreshold(threshold)
	}

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

	h.forgetPCProfile(msg.Handle) // no-op for non-PC handles
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
