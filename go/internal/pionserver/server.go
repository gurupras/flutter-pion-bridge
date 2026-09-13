package pionserver

import (
	"bytes"
	"errors"
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

// errConnClosed is returned by connWriter.enqueue once the connection is
// torn down. Producers (pion callbacks, per-DC send goroutines) treat it as
// "drop the frame" — never as a reason to panic or block.
var errConnClosed = errors.New("connection closed")

// connWriter owns the outbound side of one WebSocket connection. Producers
// enqueue pre-serialised frames; a single writer goroutine performs the
// actual conn.WriteMessage calls. close() is idempotent and unblocks every
// producer, so frames enqueued after teardown are dropped instead of
// panicking (the pre-fix behaviour was `close(writeCh)` + raw channel sends,
// which crashed the process when a dc:send ack raced a disconnect).
type connWriter struct {
	ch   chan []byte
	done chan struct{}
	once sync.Once
}

func newConnWriter(size int) *connWriter {
	return &connWriter{
		ch:   make(chan []byte, size),
		done: make(chan struct{}),
	}
}

// close marks the connection dead and unblocks all producers and the writer.
// Safe to call from any goroutine, any number of times.
func (w *connWriter) close() {
	w.once.Do(func() { close(w.done) })
}

// enqueue serialises msg and queues it for the writer goroutine. Returns
// errConnClosed (without blocking) once the connection is torn down.
func (w *connWriter) enqueue(msg Message) error {
	data, err := msgpack.Marshal(msg)
	if err != nil {
		return fmt.Errorf("msgpack marshal error: %w", err)
	}
	select {
	case <-w.done:
		return errConnClosed
	default:
	}
	select {
	case w.ch <- data:
		return nil
	case <-w.done:
		return errConnClosed
	}
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

	cw := newConnWriter(writeChanSize)
	defer cw.close()

	// Dedicated writer goroutine — the only place conn.WriteMessage is called.
	// All other goroutines enqueue pre-serialised frames via cw.enqueue. On
	// write error the writer closes both cw (unblocking all producers) and the
	// conn (unblocking the read loop) so a dead writer can never wedge the
	// connection.
	go func() {
		defer cw.close()
		defer conn.Close()
		for {
			var frame []byte
			select {
			case <-cw.done:
				return
			case frame = <-cw.ch:
			}
			if Trace.Enabled() {
				t0 := time.Now()
				if err := conn.WriteMessage(websocket.BinaryMessage, frame); err != nil {
					log.Printf("WebSocket write error: %v", err)
					return
				}
				atomic.AddInt64(&Trace.WriteFrames, 1)
				atomic.AddInt64(&Trace.WriteBytes, int64(len(frame)))
				atomic.AddInt64(&Trace.WriteNs, time.Since(t0).Nanoseconds())
			} else {
				if err := conn.WriteMessage(websocket.BinaryMessage, frame); err != nil {
					log.Printf("WebSocket write error: %v", err)
					return
				}
			}
		}
	}()

	// Set up ping-pong keepalive
	conn.SetReadDeadline(time.Now().Add(pongTimeout))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(pongTimeout))
		return nil
	})

	// Start ping ticker — uses WriteControl which has its own internal lock in
	// gorilla/websocket and does not need to go through the writer goroutine.
	pingTicker := time.NewTicker(pingInterval)
	defer pingTicker.Stop()
	go func() {
		for {
			select {
			case <-cw.done:
				return
			case <-pingTicker.C:
				if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
					return
				}
			}
		}
	}()

	handler := NewHandler(s.registry, func(event Message) {
		if err := cw.enqueue(event); err != nil && err != errConnClosed {
			log.Printf("Error enqueuing event: %v", err)
		}
	})

	// readBuf is reused for every inbound frame. This is safe because nothing
	// retains the raw frame past the loop iteration: msgpack.Unmarshal copies
	// all decoded values out of the input (pinned by
	// TestMsgpackUnmarshal_CopiesOutOfInputBuffer), and the decoded copy is
	// what flows into handlers and the per-DC send queues. gorilla's
	// ReadMessage would instead io.ReadAll into a fresh buffer per frame —
	// the top allocation site on the bridge at high dc:send rates.
	var readBuf bytes.Buffer

	for {
		messageType, reader, err := conn.NextReader()
		if err != nil {
			log.Printf("WebSocket read error: %v", err)
			// cw.close() (deferred) unblocks producers; the channel itself is
			// never closed so late acks/events are dropped, not panics.
			return
		}
		readBuf.Reset()
		if _, err := readBuf.ReadFrom(reader); err != nil {
			log.Printf("WebSocket read error: %v", err)
			return
		}
		data := readBuf.Bytes()
		if Trace.Enabled() {
			atomic.AddInt64(&Trace.ReadFrames, 1)
			atomic.AddInt64(&Trace.ReadBytes, int64(len(data)))
		}

		if messageType != websocket.BinaryMessage {
			errMsg := ErrorResponse(0, "INVALID_REQUEST", "expected binary message", false, "")
			if err := cw.enqueue(errMsg); err != nil && err != errConnClosed {
				log.Printf("Error enqueuing error response: %v", err)
			}
			continue
		}

		s.processFrame(data, handler, cw)
	}
}

// processFrame decodes one inbound protocol frame, dispatches it to handler
// and queues the response on cw. It is transport-independent: the WebSocket
// read loop and the in-process FrameSession both feed it. data may be reused
// by the caller once this returns (msgpack.Unmarshal copies out of it).
func (s *Server) processFrame(data []byte, handler *Handler, cw *connWriter) {
	// Panic recovery per message
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC recovered: %v", r)
			errMsg := ErrorResponse(0, "FATAL_PANIC", fmt.Sprintf("%v", r), true, "")
			cw.enqueue(errMsg)
		}
	}()

	msg := getMessage()
	defer putMessage(msg)

	if err := msgpack.Unmarshal(data, msg); err != nil {
		errMsg := ErrorResponse(0, "INVALID_REQUEST", "invalid msgpack: "+err.Error(), false, "")
		if err := cw.enqueue(errMsg); err != nil && err != errConnClosed {
			log.Printf("Error enqueuing error response: %v", err)
		}
		return
	}

	// Touch the handle to update lastSeen
	if msg.Handle != "" {
		s.registry.Touch(msg.Handle)
	}

	response := handler.HandleMessage(msg)
	if response.Type != "" {
		if err := cw.enqueue(response); err != nil && err != errConnClosed {
			log.Printf("Error enqueuing response: %v", err)
		}
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
