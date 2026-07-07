package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gurupras/flutter-pion-bridge/go/internal/pionserver"
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

	// Exit when the host process dies. When the host gave us a stdin PIPE it
	// holds the write end; reading blocks until EOF (host closed it or
	// crashed), at which point we exit instead of lingering as an orphan.
	//
	// Guard on the fd actually being a pipe: the Linux GTK plugin spawns us
	// with stdin as /dev/null (a character device), where reading returns
	// EOF immediately — an unconditional watchdog would kill a healthy
	// server the instant it started.
	go func() {
		fi, err := os.Stdin.Stat()
		if err != nil || fi.Mode()&os.ModeNamedPipe == 0 {
			return // stdin is not a held pipe; no parent-death signal here
		}
		io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}()

	// Block forever
	select {}
}
