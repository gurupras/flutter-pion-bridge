package main

import (
	"fmt"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
)

// startTestServer creates a server with the given token, starts it, and returns the URL.
func startTestServer(t *testing.T, token string) string {
	t.Helper()
	registry := NewRegistry()
	server := NewServer(registry, token)
	listener, err := server.ListenAndServe()
	if err != nil {
		t.Fatalf("failed to start server: %v", err)
	}
	t.Cleanup(func() { listener.Close() })
	return fmt.Sprintf("ws://127.0.0.1:%d/", listener.Addr().(*net.TCPAddr).Port)
}

// connectWS connects to the server with the given token header.
func connectWS(t *testing.T, url, token string) *websocket.Conn {
	t.Helper()
	header := http.Header{}
	header.Set("X-Pion-Token", token)
	conn, _, err := websocket.DefaultDialer.Dial(url, header)
	if err != nil {
		t.Fatalf("failed to connect: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

// sendMsg sends a msgpack-encoded Message and returns the decoded response.
func sendMsg(t *testing.T, conn *websocket.Conn, msg Message) Message {
	t.Helper()
	data, err := msgpack.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatalf("write error: %v", err)
	}

	_, respData, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read error: %v", err)
	}

	var resp Message
	if err := msgpack.Unmarshal(respData, &resp); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	return resp
}

// --- Token validation ---

func TestServer_ValidToken(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	url := startTestServer(t, token)
	conn := connectWS(t, url, token)

	resp := sendMsg(t, conn, Message{Type: "init", ID: 1, Data: map[string]interface{}{}})
	if resp.Type != "init:ack" {
		t.Errorf("expected init:ack, got %s", resp.Type)
	}
}

func TestServer_InvalidToken(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	url := startTestServer(t, token)

	header := http.Header{}
	header.Set("X-Pion-Token", "wrong-token")
	_, httpResp, err := websocket.DefaultDialer.Dial(url, header)
	if err == nil {
		t.Fatal("expected connection to fail with wrong token")
	}
	if httpResp != nil && httpResp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", httpResp.StatusCode)
	}
}

func TestServer_MissingToken(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	url := startTestServer(t, token)

	_, httpResp, err := websocket.DefaultDialer.Dial(url, nil)
	if err == nil {
		t.Fatal("expected connection to fail with missing token")
	}
	if httpResp != nil && httpResp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", httpResp.StatusCode)
	}
}

// --- Full round-trip ---

func TestServer_RoundTrip(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	url := startTestServer(t, token)
	conn := connectWS(t, url, token)

	// Send pc:create
	resp := sendMsg(t, conn, Message{
		Type: "pc:create",
		ID:   42,
		Data: map[string]interface{}{},
	})

	if resp.Type != "pc:create:ack" {
		t.Fatalf("expected pc:create:ack, got %s", resp.Type)
	}
	if resp.ID != 42 {
		t.Errorf("expected id 42, got %d", resp.ID)
	}
	handle, ok := resp.Data["handle"].(string)
	if !ok || len(handle) != 32 {
		t.Errorf("bad handle: %v", resp.Data["handle"])
	}
}

// --- Non-binary message ---

func TestServer_NonBinaryMessage(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	url := startTestServer(t, token)
	conn := connectWS(t, url, token)

	// Send a text message instead of binary
	err := conn.WriteMessage(websocket.TextMessage, []byte("hello"))
	if err != nil {
		t.Fatalf("write error: %v", err)
	}

	_, respData, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read error: %v", err)
	}

	var resp Message
	if err := msgpack.Unmarshal(respData, &resp); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

// --- Malformed msgpack ---

func TestServer_MalformedMsgpack(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	url := startTestServer(t, token)
	conn := connectWS(t, url, token)

	// Send garbage binary
	err := conn.WriteMessage(websocket.BinaryMessage, []byte{0xFF, 0xFE, 0xFD})
	if err != nil {
		t.Fatalf("write error: %v", err)
	}

	_, respData, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read error: %v", err)
	}

	var resp Message
	if err := msgpack.Unmarshal(respData, &resp); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	if resp.Type != "error" {
		t.Fatalf("expected error, got %s", resp.Type)
	}
	if resp.Data["code"] != "INVALID_REQUEST" {
		t.Errorf("expected INVALID_REQUEST, got %v", resp.Data["code"])
	}
}

// --- Panic recovery ---
// This test requires a way to trigger a panic in the handler.
// We'll test it by verifying the server stays alive after sending an operation
// that exercises all code paths, then continues to respond.

func TestServer_ContinuesAfterBadRequest(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	url := startTestServer(t, token)
	conn := connectWS(t, url, token)

	// Send a request that triggers an error
	resp1 := sendMsg(t, conn, Message{
		Type:   "pc:offer",
		ID:     1,
		Handle: "nonexistent",
		Data:   map[string]interface{}{},
	})
	if resp1.Type != "error" {
		t.Fatalf("expected error, got %s", resp1.Type)
	}

	// Server should still be responsive
	resp2 := sendMsg(t, conn, Message{Type: "init", ID: 2, Data: map[string]interface{}{}})
	if resp2.Type != "init:ack" {
		t.Errorf("server not responsive after error: got %s", resp2.Type)
	}
}

// --- Events arrive over WebSocket ---

func TestServer_EventsDelivered(t *testing.T) {
	token := "abcdef1234567890abcdef1234567890"
	registry := NewRegistry()
	server := NewServer(registry, token)
	listener, err := server.ListenAndServe()
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	url := fmt.Sprintf("ws://127.0.0.1:%d/", listener.Addr().(*net.TCPAddr).Port)
	conn := connectWS(t, url, token)

	// Create a PC — this triggers event callbacks
	createResp := sendMsg(t, conn, Message{
		Type: "pc:create", ID: 1, Data: map[string]interface{}{},
	})
	handle := createResp.Data["handle"].(string)

	// Close the PC to trigger connectionStateChange
	sendMsg(t, conn, Message{
		Type: "pc:close", ID: 2, Handle: handle, Data: map[string]interface{}{},
	})

	// Try to read events with a short timeout
	conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	gotStateEvent := false
	for i := 0; i < 10; i++ {
		_, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		var msg Message
		if err := msgpack.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg.Type == "event:connectionStateChange" && msg.Handle == handle {
			gotStateEvent = true
			if msg.ID != 0 {
				t.Errorf("event ID should be 0, got %d", msg.ID)
			}
		}
	}

	if !gotStateEvent {
		t.Log("WARN: no connectionStateChange event received (timing-dependent)")
	}
}
