package main

import (
	"fmt"
	"io"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Registry is a thread-safe handle map for WebRTC resources.
type Registry struct {
	mu        sync.RWMutex
	resources map[string]interface{}
	lastSeen  map[string]time.Time
	// parent tracks which PeerConnection owns a DataChannel (dc_handle -> pc_handle)
	parent map[string]string
	// children tracks DataChannels owned by a PeerConnection (pc_handle -> []dc_handle)
	children map[string][]string
}

// NewRegistry creates an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		resources: make(map[string]interface{}),
		lastSeen:  make(map[string]time.Time),
		parent:    make(map[string]string),
		children:  make(map[string][]string),
	}
}

// generateHandle creates a UUID v4 hex string (32 chars, no hyphens).
func generateHandle() string {
	return strings.ReplaceAll(uuid.New().String(), "-", "")
}

// Register stores a resource and returns its handle.
func (r *Registry) Register(resource interface{}) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	handle := generateHandle()
	r.resources[handle] = resource
	r.lastSeen[handle] = time.Now()
	return handle
}

// RegisterChild stores a child resource (DataChannel) linked to a parent (PeerConnection).
func (r *Registry) RegisterChild(resource interface{}, parentHandle string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	handle := generateHandle()
	r.resources[handle] = resource
	r.lastSeen[handle] = time.Now()
	r.parent[handle] = parentHandle
	r.children[parentHandle] = append(r.children[parentHandle], handle)
	return handle
}

// Lookup returns a resource by handle, updating lastSeen.
func (r *Registry) Lookup(handle string) (interface{}, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	res, ok := r.resources[handle]
	if ok {
		r.lastSeen[handle] = time.Now()
	}
	return res, ok
}

// Touch updates the lastSeen timestamp for a handle.
func (r *Registry) Touch(handle string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.resources[handle]; ok {
		r.lastSeen[handle] = time.Now()
	}
}

// Delete removes a resource and closes it if it implements io.Closer.
// If the resource is a PeerConnection, cascade-deletes its DataChannels.
func (r *Registry) Delete(handle string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.deleteLocked(handle)
}

func (r *Registry) deleteLocked(handle string) error {
	res, ok := r.resources[handle]
	if !ok {
		return fmt.Errorf("handle not found: %s", handle)
	}

	// Cascade delete children (DataChannels of a PeerConnection)
	if kids, ok := r.children[handle]; ok {
		for _, kid := range kids {
			r.deleteLocked(kid)
		}
		delete(r.children, handle)
	}

	// Close the resource (best-effort; log errors but don't fail deletion)
	if closer, ok := res.(io.Closer); ok {
		if err := closer.Close(); err != nil {
			log.Printf("warning: error closing resource %s: %v", handle, err)
		}
	}

	// Clean up parent reference
	if parentHandle, ok := r.parent[handle]; ok {
		kids := r.children[parentHandle]
		for i, kid := range kids {
			if kid == handle {
				r.children[parentHandle] = append(kids[:i], kids[i+1:]...)
				break
			}
		}
		delete(r.parent, handle)
	}

	delete(r.resources, handle)
	delete(r.lastSeen, handle)
	return nil
}

// Cleanup removes resources that haven't been seen for the given duration.
func (r *Registry) Cleanup(maxAge time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	for handle, lastSeen := range r.lastSeen {
		if now.Sub(lastSeen) > maxAge {
			r.deleteLocked(handle)
		}
	}
}

// StartCleanup runs a background goroutine that cleans up stale resources every interval.
func (r *Registry) StartCleanup(interval, maxAge time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			r.Cleanup(maxAge)
		}
	}()
}
