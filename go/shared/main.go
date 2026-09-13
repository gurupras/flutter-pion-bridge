// Command shared builds libpionbridge: the bridge as an in-process shared
// library for desktop "shared mode". Instead of a sidecar process speaking the
// protocol over a localhost WebSocket, the Dart side loads this library with
// dart:ffi and exchanges the same msgpack frames through function calls:
//
//	PionBridgeOpen(cb)          -> session id; cb receives outbound frames
//	PionBridgeSend(id, p, n)    -> push one inbound frame (copied before return)
//	PionBridgeFree(p)           -> release a frame pointer handed to cb
//	PionBridgeClose(id)         -> end the session; cb is not called afterwards
//
// Build: go build -buildmode=c-shared -o libpionbridge.so ./shared
package main

/*
#include <stdint.h>
#include <stdlib.h>

typedef void (*pion_frame_cb)(int64_t session, uint8_t *data, int32_t len);

static void pion_call_frame_cb(pion_frame_cb cb, int64_t session, uint8_t *data, int32_t len) {
	cb(session, data, len);
}
*/
import "C"

import (
	"sync"
	"time"
	"unsafe"

	"github.com/gurupras/flutter-pion-bridge/go/internal/pionserver"
)

var (
	mu       sync.Mutex
	server   *pionserver.Server
	nextID   C.int64_t = 1
	sessions           = map[C.int64_t]*pionserver.FrameSession{}
)

// ensureServer lazily creates the process-wide server. Every session shares
// its registry, exactly as every WebSocket connection shares the sidecar's.
// The Go runtime cannot be unloaded, so this lives for the process lifetime.
func ensureServer() *pionserver.Server {
	if server == nil {
		registry := pionserver.NewRegistry()
		registry.StartCleanup(30*time.Second, 300*time.Second)
		// No token: there is no socket for another local process to reach.
		server = pionserver.NewServer(registry, "")
	}
	return server
}

// PionBridgeOpen starts a protocol session. cb is invoked from a Go-owned
// thread, in order, once per outbound frame, with a malloc'd copy the callee
// must release with PionBridgeFree. Returns the session id (> 0).
//
//export PionBridgeOpen
func PionBridgeOpen(cb C.pion_frame_cb) C.int64_t {
	mu.Lock()
	defer mu.Unlock()
	id := nextID
	nextID++
	sessions[id] = ensureServer().NewFrameSession(func(frame []byte) {
		n := len(frame)
		p := C.malloc(C.size_t(max(n, 1)))
		copy(unsafe.Slice((*byte)(p), n), frame)
		C.pion_call_frame_cb(cb, id, (*C.uint8_t)(p), C.int32_t(n))
	})
	return id
}

// PionBridgeSend pushes one inbound frame. The bytes are copied before return,
// so the caller may reuse its buffer. Returns 0, or -1 for an unknown or
// closed session. Never blocks on frame processing.
//
//export PionBridgeSend
func PionBridgeSend(id C.int64_t, data *C.uint8_t, n C.int32_t) C.int32_t {
	mu.Lock()
	fs := sessions[id]
	mu.Unlock()
	if fs == nil {
		return -1
	}
	if err := fs.Push(C.GoBytes(unsafe.Pointer(data), C.int(n))); err != nil {
		return -1
	}
	return 0
}

// PionBridgeClose ends a session. When it returns, the session's callback
// will not be invoked again. Unknown ids are ignored.
//
//export PionBridgeClose
func PionBridgeClose(id C.int64_t) {
	mu.Lock()
	fs := sessions[id]
	delete(sessions, id)
	mu.Unlock()
	if fs != nil {
		fs.Close()
	}
}

// PionBridgeFree releases a frame pointer previously passed to a callback.
//
//export PionBridgeFree
func PionBridgeFree(p unsafe.Pointer) {
	C.free(p)
}

func main() {}
