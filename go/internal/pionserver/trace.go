package pionserver

import (
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// PionTrace holds atomic counters for every stage of the data pipeline.
// All fields are int64 so they can be updated with atomic.AddInt64.
// The background printer goroutine samples deltas every second and writes
// a summary line to stderr.
type PionTrace struct {
	// WebSocket read loop (one frame at a time)
	ReadFrames int64 // frames read from Dart
	ReadBytes  int64 // raw bytes (before unmarshal)

	// Per-DC send goroutine — indexed 0-15
	DCFrames [16]int64 // dc.Send() calls
	DCBytes  [16]int64 // bytes passed to dc.Send()
	DCNs     [16]int64 // nanoseconds inside dc.Send()
	DCQDepth [16]int64 // channel depth sampled just before push (peak each second)

	// Writer goroutine (events → Dart)
	WriteFrames int64
	WriteBytes  int64
	WriteNs     int64 // nanoseconds inside conn.WriteMessage

	// DC handle → trace index assignment
	mu      sync.Mutex
	dcIndex map[string]int
	nextIdx int
}

// Global trace instance.  Populated by handler/server; printed by StartTracing.
var Trace = &PionTrace{dcIndex: make(map[string]int)}

// DCIdx returns a stable 0-based index for dcHandle, allocating one on first use.
func (t *PionTrace) DCIdx(dcHandle string) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	if idx, ok := t.dcIndex[dcHandle]; ok {
		return idx
	}
	idx := t.nextIdx
	t.nextIdx++
	if idx >= 16 {
		idx = 15 // clamp — shouldn't happen in practice
	}
	t.dcIndex[dcHandle] = idx
	return idx
}

// snapshot is a point-in-time copy for delta computation.
type traceSnapshot struct {
	ReadFrames  int64
	ReadBytes   int64
	DCFrames    [16]int64
	DCBytes     [16]int64
	DCNs        [16]int64
	WriteFrames int64
	WriteBytes  int64
	WriteNs     int64
}

func captureSnapshot(t *PionTrace) traceSnapshot {
	var s traceSnapshot
	s.ReadFrames = atomic.LoadInt64(&t.ReadFrames)
	s.ReadBytes = atomic.LoadInt64(&t.ReadBytes)
	for i := range s.DCFrames {
		s.DCFrames[i] = atomic.LoadInt64(&t.DCFrames[i])
		s.DCBytes[i] = atomic.LoadInt64(&t.DCBytes[i])
		s.DCNs[i] = atomic.LoadInt64(&t.DCNs[i])
	}
	s.WriteFrames = atomic.LoadInt64(&t.WriteFrames)
	s.WriteBytes = atomic.LoadInt64(&t.WriteBytes)
	s.WriteNs = atomic.LoadInt64(&t.WriteNs)
	return s
}

// StartTracing launches a background goroutine that prints a per-second
// summary of all pipeline counters to stderr.
func StartTracing(label string) {
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		start := time.Now()
		prev := captureSnapshot(Trace)

		for tick := range ticker.C {
			cur := captureSnapshot(Trace)
			dt := tick.Sub(start).Seconds()

			dReadFrames := cur.ReadFrames - prev.ReadFrames
			dReadBytes := cur.ReadBytes - prev.ReadBytes
			dWriteFrames := cur.WriteFrames - prev.WriteFrames
			dWriteBytes := cur.WriteBytes - prev.WriteBytes
			dWriteNs := cur.WriteNs - prev.WriteNs

			var writeAvgUs float64
			if dWriteFrames > 0 {
				writeAvgUs = float64(dWriteNs) / float64(dWriteFrames) / 1000
			}

			line := fmt.Sprintf("[PION/%s t=%4.0fs] read: %5d f/s %6.1f MB/s | write: %5d f/s %6.1f MB/s avg=%5.1fµs",
				label, dt,
				dReadFrames, float64(dReadBytes)/1e6,
				dWriteFrames, float64(dWriteBytes)/1e6, writeAvgUs,
			)

			// Print active DC slots
			Trace.mu.Lock()
			nDC := Trace.nextIdx
			Trace.mu.Unlock()
			for i := 0; i < nDC && i < 16; i++ {
				df := cur.DCFrames[i] - prev.DCFrames[i]
				db := cur.DCBytes[i] - prev.DCBytes[i]
				dn := cur.DCNs[i] - prev.DCNs[i]
				qd := atomic.LoadInt64(&Trace.DCQDepth[i])
				var avgUs float64
				if df > 0 {
					avgUs = float64(dn) / float64(df) / 1000
				}
				line += fmt.Sprintf(" | DC%d: %5d f/s %6.1f MB/s avg=%5.1fµs qdepth=%d",
					i, df, float64(db)/1e6, avgUs, qd)
			}

			fmt.Fprintln(os.Stderr, line)
			prev = cur
		}
	}()
}
