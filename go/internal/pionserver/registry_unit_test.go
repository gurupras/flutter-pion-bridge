package pionserver

import (
	"sync"
	"testing"
	"time"
)

// mockCloser tracks whether Close() was called.
type mockCloser struct {
	closed bool
}

func (m *mockCloser) Close() error {
	m.closed = true
	return nil
}

func TestRegister_ReturnsValidHandle(t *testing.T) {
	r := NewRegistry()
	handle := r.Register("resource1")

	if len(handle) != 32 {
		t.Errorf("expected 32-char handle, got %d chars: %s", len(handle), handle)
	}

	// Should be hex characters only
	for _, c := range handle {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			t.Errorf("handle contains non-hex char: %c", c)
		}
	}
}

func TestLookup_ReturnsResourceAndUpdatesLastSeen(t *testing.T) {
	r := NewRegistry()
	handle := r.Register("resource1")

	// Wait a bit so lastSeen is distinguishable
	time.Sleep(5 * time.Millisecond)

	res, ok := r.Lookup(handle)
	if !ok {
		t.Fatal("expected Lookup to return true")
	}
	if res != "resource1" {
		t.Errorf("expected resource1, got %v", res)
	}

	// Verify lastSeen was updated (it should be very recent)
	r.mu.RLock()
	ls := r.lastSeen[handle]
	r.mu.RUnlock()
	if time.Since(ls) > 100*time.Millisecond {
		t.Error("lastSeen was not updated by Lookup")
	}
}

func TestLookup_UnknownHandle(t *testing.T) {
	r := NewRegistry()
	_, ok := r.Lookup("nonexistent")
	if ok {
		t.Error("expected Lookup to return false for unknown handle")
	}
}

func TestDelete_RemovesResourceAndCallsClose(t *testing.T) {
	r := NewRegistry()
	m := &mockCloser{}
	handle := r.Register(m)

	err := r.Delete(handle)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !m.closed {
		t.Error("expected Close() to be called")
	}

	_, ok := r.Lookup(handle)
	if ok {
		t.Error("expected handle to be removed after Delete")
	}
}

func TestDelete_UnknownHandle(t *testing.T) {
	r := NewRegistry()
	err := r.Delete("nonexistent")
	if err == nil {
		t.Error("expected error for deleting unknown handle")
	}
}

func TestRegisterChild_LinksChildToParent(t *testing.T) {
	r := NewRegistry()
	parentHandle := r.Register("parent")
	childHandle := r.RegisterChild("child", parentHandle)

	// Both should be lookupable
	_, ok := r.Lookup(parentHandle)
	if !ok {
		t.Error("parent not found")
	}
	_, ok = r.Lookup(childHandle)
	if !ok {
		t.Error("child not found")
	}

	// Verify parent-child relationship
	r.mu.RLock()
	p, ok := r.parent[childHandle]
	r.mu.RUnlock()
	if !ok || p != parentHandle {
		t.Error("child's parent not set correctly")
	}

	r.mu.RLock()
	kids := r.children[parentHandle]
	r.mu.RUnlock()
	found := false
	for _, k := range kids {
		if k == childHandle {
			found = true
			break
		}
	}
	if !found {
		t.Error("child not in parent's children list")
	}
}

func TestDelete_ParentCascadesToChildren(t *testing.T) {
	r := NewRegistry()
	parentCloser := &mockCloser{}
	child1Closer := &mockCloser{}
	child2Closer := &mockCloser{}

	parentHandle := r.Register(parentCloser)
	child1Handle := r.RegisterChild(child1Closer, parentHandle)
	child2Handle := r.RegisterChild(child2Closer, parentHandle)

	err := r.Delete(parentHandle)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !parentCloser.closed {
		t.Error("parent Close() not called")
	}
	if !child1Closer.closed {
		t.Error("child1 Close() not called")
	}
	if !child2Closer.closed {
		t.Error("child2 Close() not called")
	}

	// All handles should be gone
	for _, h := range []string{parentHandle, child1Handle, child2Handle} {
		if _, ok := r.Lookup(h); ok {
			t.Errorf("handle %s should have been deleted", h)
		}
	}
}

func TestCleanup_RemovesStaleHandles(t *testing.T) {
	r := NewRegistry()
	handle := r.Register("stale")

	// Manually set lastSeen to the past
	r.mu.Lock()
	r.lastSeen[handle] = time.Now().Add(-10 * time.Minute)
	r.mu.Unlock()

	r.Cleanup(5 * time.Minute)

	if _, ok := r.Lookup(handle); ok {
		t.Error("stale handle should have been cleaned up")
	}
}

func TestCleanup_LeavesFreshHandles(t *testing.T) {
	r := NewRegistry()
	handle := r.Register("fresh")

	r.Cleanup(5 * time.Minute)

	if _, ok := r.Lookup(handle); !ok {
		t.Error("fresh handle should NOT have been cleaned up")
	}
}

func TestConcurrentAccess(t *testing.T) {
	r := NewRegistry()
	var wg sync.WaitGroup

	// Concurrent Register
	handles := make([]string, 100)
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			handles[idx] = r.Register(idx)
		}(i)
	}
	wg.Wait()

	// Concurrent Lookup + Delete
	for i := 0; i < 100; i++ {
		wg.Add(2)
		go func(idx int) {
			defer wg.Done()
			r.Lookup(handles[idx])
		}(i)
		go func(idx int) {
			defer wg.Done()
			r.Delete(handles[idx])
		}(i)
	}
	wg.Wait()
}
