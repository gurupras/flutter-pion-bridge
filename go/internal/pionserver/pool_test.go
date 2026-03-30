package pionserver

import (
	"sync"
	"testing"
)

// TestMessagePool_NoDataLeakage verifies that reused messages don't leak data.
func TestMessagePool_NoDataLeakage(t *testing.T) {
	// Get first message from pool, fill it with data
	msg1 := getMessage()
	msg1.Type = "test:type"
	msg1.ID = 42
	msg1.Handle = "secret-handle-abc123"
	msg1.Data["sensitive"] = "should-not-leak"
	msg1.Data["user_id"] = 999

	// Return it to pool
	putMessage(msg1)

	// Get another message from pool - should be the same object (pooled)
	msg2 := getMessage()

	// Verify fields are cleared
	if msg2.Type != "" {
		t.Errorf("Type not cleared: got %q, want empty", msg2.Type)
	}
	if msg2.ID != 0 {
		t.Errorf("ID not cleared: got %d, want 0", msg2.ID)
	}
	if msg2.Handle != "" {
		t.Errorf("Handle not cleared: got %q, want empty", msg2.Handle)
	}

	// Verify map is empty (no sensitive data leak)
	if len(msg2.Data) != 0 {
		t.Errorf("Data map not cleared: got %v, want empty", msg2.Data)
	}

	// Use the reused message with new data
	msg2.Type = "new:type"
	msg2.Data["public"] = "safe-data"

	// Return and reuse again
	putMessage(msg2)
	msg3 := getMessage()

	if msg3.Data["sensitive"] != nil {
		t.Errorf("Old data leaked from pool: sensitive=%v", msg3.Data["sensitive"])
	}
	if msg3.Data["user_id"] != nil {
		t.Errorf("Old data leaked from pool: user_id=%v", msg3.Data["user_id"])
	}
	if msg3.Data["public"] != nil {
		t.Errorf("Previous message data leaked: public=%v", msg3.Data["public"])
	}
}

// TestMessagePool_ConcurrentAccess tests that the pool is safe under concurrent load.
func TestMessagePool_ConcurrentAccess(t *testing.T) {
	const (
		goroutines = 100
		iterations = 1000
	)

	var wg sync.WaitGroup
	wg.Add(goroutines)

	// Track data corruption: if any goroutine sees unexpected data, fail
	var corrupted bool
	var corruptMu sync.Mutex

	for g := 0; g < goroutines; g++ {
		go func(goroutineID int) {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				msg := getMessage()

				// Poison the message with goroutine+iteration-specific data
				expectedType := msg_type(goroutineID, i)
				expectedData := msg_data(goroutineID, i)

				msg.Type = expectedType
				msg.ID = goroutineID*iterations + i
				msg.Data["value"] = expectedData

				// Yield to let other goroutines interleave
				if i%10 == 0 {
					// (no explicit yield in Go, but context switch happens naturally)
				}

				// Verify our data is still intact
				if msg.Type != expectedType {
					corruptMu.Lock()
					corrupted = true
					corruptMu.Unlock()
					t.Errorf("goroutine %d iteration %d: Type corruption: got %q, want %q",
						goroutineID, i, msg.Type, expectedType)
				}
				if msg.Data["value"] != expectedData {
					corruptMu.Lock()
					corrupted = true
					corruptMu.Unlock()
					t.Errorf("goroutine %d iteration %d: Data corruption: got %q, want %q",
						goroutineID, i, msg.Data["value"], expectedData)
				}

				putMessage(msg)
			}
		}(g)
	}

	wg.Wait()

	if corrupted {
		t.Fatal("Pool exhibited data corruption under concurrent access")
	}
}

// TestMessagePool_MapCleared verifies that the map is properly cleared when reused.
func TestMessagePool_MapCleared(t *testing.T) {
	msg1 := getMessage()
	msg1.Data["a"] = 1
	msg1.Data["b"] = 2
	msg1.Data["c"] = 3

	if len(msg1.Data) != 3 {
		t.Errorf("Expected 3 entries, got %d", len(msg1.Data))
	}

	putMessage(msg1)

	msg2 := getMessage()

	// The map must be empty (all keys deleted)
	if len(msg2.Data) != 0 {
		t.Errorf("Map not cleared: has %d entries: %v", len(msg2.Data), msg2.Data)
	}
}

// TestMessagePool_DeferredCleanup verifies that putMessage is reliably called.
func TestMessagePool_DeferredCleanup(t *testing.T) {
	msg := getMessage()
	msg.Type = "sensitive"
	msg.Data["secret"] = "should-be-cleaned"

	// Simulate deferred cleanup (as used in server.go)
	func() {
		defer putMessage(msg)
		// ... do work ...
	}()

	// Verify the message was cleaned
	if msg.Type != "" {
		t.Errorf("Deferred cleanup failed: Type still set to %q", msg.Type)
	}
	if len(msg.Data) != 0 {
		t.Errorf("Deferred cleanup failed: Data still contains %v", msg.Data)
	}
}

// Helper functions to generate deterministic test data

func msg_type(goroutineID, iteration int) string {
	return "test:type:" + string(rune(goroutineID)) + ":" + string(rune(iteration))
}

func msg_data(goroutineID, iteration int) string {
	return "data:g" + string(rune(goroutineID)) + "i" + string(rune(iteration))
}
