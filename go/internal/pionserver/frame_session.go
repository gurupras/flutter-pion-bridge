package pionserver

import (
	"errors"
	"sync"
)

// ErrSessionClosed is returned by FrameSession.Push after Close.
var ErrSessionClosed = errors.New("frame session closed")

// FrameSession is one protocol session without a socket: the in-process
// ("shared") transport. The caller pushes inbound msgpack frames and receives
// outbound frames through deliver. It has the same semantics as one WebSocket
// connection — its own Handler, serial processing of inbound frames, a single
// ordered writer — and shares the Server's registry with every other session.
type FrameSession struct {
	in         chan []byte
	cw         *connWriter
	once       sync.Once
	done       chan struct{}
	writerDone chan struct{}
}

// NewFrameSession starts a session. deliver is called from a single goroutine,
// in order, once per outbound frame; it owns the slice it is given. deliver is
// never called after Close returns, so it may hand frames to a callback whose
// lifetime ends with the session (e.g. a Dart NativeCallable).
func (s *Server) NewFrameSession(deliver func(frame []byte)) *FrameSession {
	fs := &FrameSession{
		in:         make(chan []byte, writeChanSize),
		cw:         newConnWriter(writeChanSize),
		done:       make(chan struct{}),
		writerDone: make(chan struct{}),
	}

	// Writer: the counterpart of the WebSocket writer goroutine.
	go func() {
		defer close(fs.writerDone)
		for {
			select {
			case <-fs.cw.done:
				return
			case frame := <-fs.cw.ch:
				// Recheck after a ready frame: select picks randomly when both
				// cases are ready, and nothing may be delivered after Close.
				select {
				case <-fs.cw.done:
					return
				default:
				}
				deliver(frame)
			}
		}
	}()

	handler := NewHandler(s.registry, func(event Message) {
		_ = fs.cw.enqueue(event)
	})

	// Reader: the counterpart of the WebSocket read loop. Inbound frames are
	// processed serially, exactly as they are per connection today.
	go func() {
		for {
			select {
			case <-fs.done:
				return
			case frame := <-fs.in:
				s.processFrame(frame, handler, fs.cw)
			}
		}
	}()
	return fs
}

// Push queues one inbound frame. The session takes ownership of frame.
func (fs *FrameSession) Push(frame []byte) error {
	select {
	case <-fs.done:
		return ErrSessionClosed
	default:
	}
	select {
	case fs.in <- frame:
		return nil
	case <-fs.done:
		return ErrSessionClosed
	}
}

// Close ends the session and returns once the writer has stopped, so deliver
// is never called afterwards. Frames still queued in either direction are
// dropped, as they are when a WebSocket disconnects. Idempotent. Must not be
// called from inside deliver.
func (fs *FrameSession) Close() {
	fs.once.Do(func() {
		close(fs.done)
		fs.cw.close()
	})
	<-fs.writerDone
}
