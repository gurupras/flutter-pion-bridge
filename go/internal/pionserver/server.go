package pionserver

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
)

const (
	// Keepalive intervals
	pingInterval = 15 * time.Second
	pongTimeout  = 30 * time.Second

	// writeChanSize is the number of pre-serialised frames that can be queued
	// before producers block.  Each frame is at most ~64 KB, so 8192 slots is
	// up to ~512 MB of headroom — plenty for a multi-connection benchmark.
	writeChanSize = 8192
)

// messagePool provides reusable Message structs to reduce allocations on the hot path.
var messagePool = sync.Pool{
	New: func() interface{} {
		return &Message{
			Data: make(map[string]interface{}, 8),
		}
	},
}

// getMessage retrieves a Message from the pool, or allocates a new one.
func getMessage() *Message {
	m := messagePool.Get().(*Message)
	return m
}

// putMessage clears and returns a Message to the pool.
// Callers must ensure the message is no longer referenced after calling this.
func putMessage(m *Message) {
	// Zero the message fields to avoid data leakage
	m.Type = ""
	m.ID = 0
	m.Handle = ""
	// Clear the data map (preserves underlying capacity for reuse)
	for k := range m.Data {
		delete(m.Data, k)
	}
	messagePool.Put(m)
}

// Server is the WebSocket server that handles PionBridge protocol messages.
type Server struct {
	registry *Registry
	token    string
	upgrader websocket.Upgrader
}

// NewServer creates a new WebSocket server.
func NewServer(registry *Registry, token string) *Server {
	return &Server{
		registry: registry,
		token:    token,
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
}

// enqueueMessage serialises msg to msgpack and pushes the bytes onto writeCh.
// Multiple goroutines may call this concurrently; the actual WebSocket write
// is performed by the single writer goroutine, so no lock is needed here.
func enqueueMessage(writeCh chan<- []byte, msg Message) error {
	data, err := msgpack.Marshal(msg)
	if err != nil {
		return fmt.Errorf("msgpack marshal error: %w", err)
	}
	writeCh <- data // blocks only when the channel is full
	return nil
}

// handleWebSocket is the HTTP handler for WebSocket upgrades.
func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	// Validate session token
	token := r.Header.Get("X-Pion-Token")
	if token != s.token {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}
	defer conn.Close()

	// Dedicated writer goroutine — the only place conn.WriteMessage is called.
	// All other goroutines push pre-serialised frames onto writeCh.
	writeCh := make(chan []byte, writeChanSize)
	go func() {
		for frame := range writeCh {
			t0 := time.Now()
			if err := conn.WriteMessage(websocket.BinaryMessage, frame); err != nil {
				log.Printf("WebSocket write error: %v", err)
				return
			}
			atomic.AddInt64(&Trace.WriteFrames, 1)
			atomic.AddInt64(&Trace.WriteBytes, int64(len(frame)))
			atomic.AddInt64(&Trace.WriteNs, time.Since(t0).Nanoseconds())
		}
	}()

	// Set up ping-pong keepalive
	conn.SetReadDeadline(time.Now().Add(pongTimeout))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(pongTimeout))
		return nil
	})

	// Start ping ticker — uses WriteControl which has its own internal lock in
	// gorilla/websocket and does not need to go through writeCh.
	pingTicker := time.NewTicker(pingInterval)
	defer pingTicker.Stop()
	go func() {
		for range pingTicker.C {
			if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				return
			}
		}
	}()

	handler := NewHandler(s.registry, func(event Message) {
		if err := enqueueMessage(writeCh, event); err != nil {
			log.Printf("Error enqueuing event: %v", err)
		}
	})

	for {
		messageType, data, err := conn.ReadMessage()
		if err != nil {
			log.Printf("WebSocket read error: %v", err)
			close(writeCh)
			return
		}
		atomic.AddInt64(&Trace.ReadFrames, 1)
		atomic.AddInt64(&Trace.ReadBytes, int64(len(data)))

		if messageType != websocket.BinaryMessage {
			errMsg := ErrorResponse(0, "INVALID_REQUEST", "expected binary message", false, "")
			enqueueMessage(writeCh, errMsg)
			continue
		}

		// Panic recovery per message
		func() {
			defer func() {
				if r := recover(); r != nil {
					log.Printf("PANIC recovered: %v", r)
					errMsg := ErrorResponse(0, "FATAL_PANIC", fmt.Sprintf("%v", r), true, "")
					enqueueMessage(writeCh, errMsg)
				}
			}()

			msg := getMessage()
			defer putMessage(msg)

			if err := msgpack.Unmarshal(data, msg); err != nil {
				errMsg := ErrorResponse(0, "INVALID_REQUEST", "invalid msgpack: "+err.Error(), false, "")
				enqueueMessage(writeCh, errMsg)
				return
			}

			// Touch the handle to update lastSeen
			if msg.Handle != "" {
				s.registry.Touch(msg.Handle)
			}

			response := handler.HandleMessage(msg)
			if response.Type != "" {
				if err := enqueueMessage(writeCh, response); err != nil {
					log.Printf("Error enqueuing response: %v", err)
				}
			}
		}()
	}
}

// ListenAndServe starts the WebSocket server on localhost with an ephemeral port.
// Returns the listener (to get the port) and starts serving in the background.
func (s *Server) ListenAndServe() (net.Listener, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleWebSocket)

	go func() {
		if err := http.Serve(listener, mux); err != nil {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	return listener, nil
}
