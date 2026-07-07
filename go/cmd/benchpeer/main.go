// benchpeer is the remote side of the cross-machine WebRTC benchmark.
//
// It is a self-contained answerer: it serves the JSON signaling protocol on
// a WebSocket port, answers one peer, sinks upload bytes, sources download
// bytes (with buffered-amount backpressure), and echoes PING:i → PONG:i text
// frames for RTT measurement. Built statically and copied to a LAN host so
// the remote end stays CONSTANT while the local end swaps between baseline
// and patched builds.
//
//	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o benchpeer ./cmd/benchpeer
//	scp benchpeer <host>: && ssh <host> ./benchpeer --port 8765
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
)

type sigMsg struct {
	T             string          `json:"t"`
	SDP           string          `json:"sdp,omitempty"`
	Candidate     string          `json:"candidate,omitempty"`
	SDPMid        *string         `json:"sdpMid,omitempty"`
	SDPMlineIndex *uint16         `json:"sdpMlineIndex,omitempty"`
	Bytes         int             `json:"bytes,omitempty"`
	Ms            int64           `json:"ms,omitempty"`
	Results       json.RawMessage `json:"results,omitempty"`
}

func main() {
	port := flag.Int("port", 8765, "signaling port")
	flag.Parse()

	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	done := make(chan struct{})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("upgrade: %v", err)
			return
		}
		defer ws.Close()
		var wsMu sync.Mutex
		send := func(m sigMsg) {
			wsMu.Lock()
			defer wsMu.Unlock()
			if err := ws.WriteJSON(m); err != nil {
				log.Printf("sig write: %v", err)
			}
		}

		pc, err := webrtc.NewPeerConnection(webrtc.Configuration{})
		if err != nil {
			log.Printf("pc: %v", err)
			return
		}
		defer pc.Close()

		pc.OnICECandidate(func(c *webrtc.ICECandidate) {
			if c == nil {
				return
			}
			init := c.ToJSON()
			send(sigMsg{T: "ice", Candidate: init.Candidate,
				SDPMid: init.SDPMid, SDPMlineIndex: init.SDPMLineIndex})
		})

		var (
			mu         sync.Mutex
			upExpected int
			upReceived int
			upStart    time.Time
			dcRef      *webrtc.DataChannel
			sendMore   = make(chan struct{}, 1)
		)

		pc.OnDataChannel(func(dc *webrtc.DataChannel) {
			mu.Lock()
			dcRef = dc
			mu.Unlock()
			dc.SetBufferedAmountLowThreshold(512 * 1024)
			dc.OnBufferedAmountLow(func() {
				select {
				case sendMore <- struct{}{}:
				default:
				}
			})
			dc.OnMessage(func(m webrtc.DataChannelMessage) {
				if m.IsString {
					s := string(m.Data)
					if len(s) > 5 && s[:5] == "PING:" {
						if err := dc.SendText("PONG:" + s[5:]); err != nil {
							log.Printf("pong: %v", err)
						}
					}
					return
				}
				mu.Lock()
				upReceived += len(m.Data)
				if upExpected > 0 && upReceived >= upExpected {
					ms := time.Since(upStart).Milliseconds()
					upExpected = 0
					mu.Unlock()
					send(sigMsg{T: "up-done", Ms: ms})
					return
				}
				mu.Unlock()
			})
		})

		for {
			var m sigMsg
			if err := ws.ReadJSON(&m); err != nil {
				log.Printf("sig read: %v", err)
				return
			}
			switch m.T {
			case "hello":
				send(sigMsg{T: "hello-ack"})
			case "offer":
				if err := pc.SetRemoteDescription(webrtc.SessionDescription{
					Type: webrtc.SDPTypeOffer, SDP: m.SDP}); err != nil {
					log.Printf("setRemote: %v", err)
					return
				}
				answer, err := pc.CreateAnswer(nil)
				if err != nil {
					log.Printf("answer: %v", err)
					return
				}
				if err := pc.SetLocalDescription(answer); err != nil {
					log.Printf("setLocal: %v", err)
					return
				}
				send(sigMsg{T: "answer", SDP: answer.SDP})
			case "ice":
				if err := pc.AddICECandidate(webrtc.ICECandidateInit{
					Candidate: m.Candidate, SDPMid: m.SDPMid,
					SDPMLineIndex: m.SDPMlineIndex}); err != nil {
					log.Printf("addIce: %v", err)
				}
			case "up-start":
				mu.Lock()
				upExpected = m.Bytes
				upReceived = 0
				upStart = time.Now()
				mu.Unlock()
			case "down-start":
				mu.Lock()
				dc := dcRef
				mu.Unlock()
				if dc == nil {
					log.Printf("down-start before DataChannel")
					continue
				}
				go func(total int) {
					chunk := make([]byte, 64*1024)
					for i := range chunk {
						chunk[i] = byte(i)
					}
					start := time.Now()
					sent := 0
					for sent < total {
						n := len(chunk)
						if total-sent < n {
							n = total - sent
						}
						if dc.BufferedAmount() > 1024*1024 {
							<-sendMore
						}
						if err := dc.Send(chunk[:n]); err != nil {
							log.Printf("down send: %v", err)
							return
						}
						sent += n
					}
					send(sigMsg{T: "down-sent", Ms: time.Since(start).Milliseconds()})
				}(m.Bytes)
			case "bye":
				fmt.Printf("BENCH-RESULTS %s\n", string(m.Results))
				// Keep serving: the A/B harness reconnects for each run.
			}
		}
	})

	log.Printf("benchpeer listening on :%d", *port)
	srv := &http.Server{Addr: fmt.Sprintf(":%d", *port)}
	go func() {
		<-done
		srv.Close()
	}()
	if err := srv.ListenAndServe(); err != nil {
		log.Printf("serve: %v", err)
	}
}
