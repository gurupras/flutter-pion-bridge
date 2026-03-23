// Package mobile exposes PionBridge for gomobile bind (iOS / Android AAR).
// It is compiled via `gomobile bind -target ios` to produce PionBridgeGo.xcframework.
package mobile

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/pion-bridge/server/internal/pionserver"
)

// StartResult holds the listening port and session token after a successful Start().
type StartResult struct {
	Port  int
	Token string
}

var (
	mu       sync.Mutex
	listener net.Listener
)

// Start starts the PionBridge WebSocket server on an ephemeral loopback port.
// Returns port and token that the Dart layer uses to connect.
// Calling Start() while already running returns an error.
func Start() (*StartResult, error) {
	mu.Lock()
	defer mu.Unlock()

	if listener != nil {
		return nil, fmt.Errorf("server already running")
	}

	registry := pionserver.NewRegistry()
	registry.StartCleanup(30*time.Second, 300*time.Second)

	token := strings.ReplaceAll(uuid.New().String(), "-", "")
	server := pionserver.NewServer(registry, token)

	l, err := server.ListenAndServe()
	if err != nil {
		return nil, err
	}

	listener = l
	port := l.Addr().(*net.TCPAddr).Port

	return &StartResult{Port: port, Token: token}, nil
}

// Stop stops the PionBridge server. Safe to call when not running.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()

	if listener == nil {
		return nil
	}

	err := listener.Close()
	listener = nil
	return err
}
