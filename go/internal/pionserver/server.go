package pionserver

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
)

const (
	// Keepalive intervals
	pingInterval = 15 * time.Second
	pongTimeout  = 30 * time.Second
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
	// mu protects conn for concurrent event sends
	mu   sync.Mutex
	conn *websocket.Conn
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

// sendMessage sends a MessagePack-encoded message over the WebSocket.
func (s *Server) sendMessage(conn *websocket.Conn, msg Message) error {
	data, err := msgpack.Marshal(msg)
	if err != nil {
		return fmt.Errorf("msgpack marshal error: %w", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return conn.WriteMessage(websocket.BinaryMessage, data)
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

	s.mu.Lock()
	s.conn = conn
	s.mu.Unlock()

	// Set up ping-pong keepalive
	conn.SetReadDeadline(time.Now().Add(pongTimeout))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(pongTimeout))
		return nil
	})

	// Start ping ticker
	pingTicker := time.NewTicker(pingInterval)
	defer pingTicker.Stop()
	go func() {
		for range pingTicker.C {
			s.mu.Lock()
			err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
			s.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()

	handler := NewHandler(s.registry, func(event Message) {
		if err := s.sendMessage(conn, event); err != nil {
			log.Printf("Error sending event: %v", err)
		}
	})

	for {
		messageType, data, err := conn.ReadMessage()
		if err != nil {
			log.Printf("WebSocket read error: %v", err)
			return
		}

		if messageType != websocket.BinaryMessage {
			errMsg := ErrorResponse(0, "INVALID_REQUEST", "expected binary message", false, "")
			s.sendMessage(conn, errMsg)
			continue
		}

		// Panic recovery per message
		func() {
			defer func() {
				if r := recover(); r != nil {
					log.Printf("PANIC recovered: %v", r)
					errMsg := ErrorResponse(0, "FATAL_PANIC", fmt.Sprintf("%v", r), true, "")
					s.sendMessage(conn, errMsg)
				}
			}()

			msg := getMessage()
			defer putMessage(msg)

			if err := msgpack.Unmarshal(data, msg); err != nil {
				errMsg := ErrorResponse(0, "INVALID_REQUEST", "invalid msgpack: "+err.Error(), false, "")
				s.sendMessage(conn, errMsg)
				return
			}

			// Touch the handle to update lastSeen
			if msg.Handle != "" {
				s.registry.Touch(msg.Handle)
			}

			response := handler.HandleMessage(msg) // msg is *Message from pool
			if err := s.sendMessage(conn, response); err != nil {
				log.Printf("Error sending response: %v", err)
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
