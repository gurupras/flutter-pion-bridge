package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/pion-bridge/server/internal/pionserver"
)

func main() {
	// Initialize registry
	registry := pionserver.NewRegistry()

	// Start background cleanup: every 30s, remove handles older than 300s
	registry.StartCleanup(30*time.Second, 300*time.Second)

	// Generate session token: UUID v4 hex (32 chars, no hyphens, lowercase)
	token := strings.ReplaceAll(uuid.New().String(), "-", "")

	// Create and start WebSocket server
	server := pionserver.NewServer(registry, token)
	listener, err := server.ListenAndServe()
	if err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}

	port := listener.Addr().(*net.TCPAddr).Port

	// Output startup JSON to stdout
	startup := map[string]interface{}{
		"port":  port,
		"token": token,
	}
	startupJSON, err := json.Marshal(startup)
	if err != nil {
		log.Fatalf("Failed to marshal startup JSON: %v", err)
	}
	fmt.Println(string(startupJSON))

	// Flush stdout
	os.Stdout.Sync()

	// Block forever
	select {}
}
