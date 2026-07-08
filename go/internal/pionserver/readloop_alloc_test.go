package pionserver

import (
	"bytes"
	"runtime"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
)

// TestReadLoop_NoPerFrameBufferAlloc guards the read loop's frame-buffer
// reuse. gorilla's ReadMessage allocates a fresh buffer per frame via
// io.ReadAll (~4x the payload size counting append-doubling), which was the
// single largest allocation site in the sender bridge under profiling at
// ~100k frames/s. The read loop must instead reuse one buffer per
// connection, leaving only the unavoidable msgpack decode copy (~1x).
//
// The threshold sits between the two regimes: reused-buffer steady state
// allocates ~1.1x the frame size per frame (decode copy + response
// serialization), ReadMessage allocates ~4x.
func TestReadLoop_NoPerFrameBufferAlloc(t *testing.T) {
	url := startTestServer(t, "alloc-token")
	conn := connectWS(t, url, "alloc-token")

	const payloadSize = 64 * 1024
	const frames = 100

	payload := make([]byte, payloadSize)
	for i := range payload {
		payload[i] = byte(i)
	}
	// Marshal once and resend the same frame so the client side contributes
	// ~zero allocation per frame; the measurement isolates the server.
	frame, err := msgpack.Marshal(Message{
		Type:   "dc:send",
		ID:     1,
		Handle: "nonexistent-handle",
		Data:   map[string]interface{}{"data": payload},
	})
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}

	sendAndAwait := func(n int) {
		for i := 0; i < n; i++ {
			if err := conn.WriteMessage(websocket.BinaryMessage, frame); err != nil {
				t.Fatalf("write error: %v", err)
			}
			// Reading the (error) response serializes the loop: the server has
			// fully processed frame i before the next one is sent.
			if _, _, err := conn.ReadMessage(); err != nil {
				t.Fatalf("read error: %v", err)
			}
		}
	}

	// Warm up: let the connection's reusable buffer grow to frame size and
	// sync.Pools populate before measuring.
	sendAndAwait(5)

	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	sendAndAwait(frames)
	runtime.ReadMemStats(&after)

	perFrame := (after.TotalAlloc - before.TotalAlloc) / frames
	// Reused buffer: ~72 KB/frame. ReadMessage/io.ReadAll: ~260+ KB/frame.
	const maxPerFrame = payloadSize * 5 / 2
	t.Logf("allocated %d bytes/frame (limit %d)", perFrame, maxPerFrame)
	if perFrame > maxPerFrame {
		t.Errorf("read path allocates %d bytes per %d-byte frame (limit %d): frame buffer is not being reused",
			perFrame, payloadSize, maxPerFrame)
	}
}

// TestMsgpackUnmarshal_CopiesOutOfInputBuffer pins the library property that
// frame-buffer reuse depends on: msgpack.Unmarshal must copy binary and
// string values out of the input buffer, never alias it. The decoded payload
// outlives the frame (dc:send queues it on the per-DC FIFO), so if a msgpack
// upgrade ever introduced zero-copy decoding, reusing the read buffer would
// corrupt queued payloads — this test turns that into a red build instead.
func TestMsgpackUnmarshal_CopiesOutOfInputBuffer(t *testing.T) {
	payload := make([]byte, 4096)
	for i := range payload {
		payload[i] = byte(i % 251)
	}
	frame, err := msgpack.Marshal(Message{
		Type:   "dc:send",
		ID:     42,
		Handle: "handle-abc",
		Data:   map[string]interface{}{"data": payload, "label": "hello"},
	})
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}

	var msg Message
	if err := msgpack.Unmarshal(frame, &msg); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	// Scribble over the input buffer, as a reused read buffer would.
	for i := range frame {
		frame[i] = 0xFF
	}

	got, ok := msg.Data["data"].([]byte)
	if !ok {
		t.Fatalf("payload decoded as %T, want []byte", msg.Data["data"])
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("decoded payload aliases the input buffer: corrupted after buffer reuse")
	}
	if msg.Type != "dc:send" || msg.Handle != "handle-abc" {
		t.Fatalf("decoded strings corrupted after buffer reuse: type=%q handle=%q", msg.Type, msg.Handle)
	}
	if label, _ := msg.Data["label"].(string); label != "hello" {
		t.Fatalf("decoded map string corrupted after buffer reuse: %q", label)
	}
}
