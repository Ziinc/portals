package portals

import (
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
)

// Bidirectional streaming for the Go worker SDK (protocol/v1.md section 9).
//
// A stream is opened by the BEAM as an ordinary CALL whose target was
// registered with Worker.HandleStream; the call's request_id doubles as the
// stream_id. The handler receives a *Stream and runs under a stream
// concurrency budget kept separate from the unary one, so long-lived
// streams can never exhaust the concurrency this worker advertised for
// unary calls.
//
// Backpressure is an encoded-byte credit window, independent per
// direction, charged against the complete encoded frame size (4-byte
// length prefix included), plus a hard cap on queued-but-unconsumed frames
// so a flood of tiny frames cannot evade the byte window.

// errStreamProtocol marks a peer that exceeded its documented byte or
// frame allowance.
var errStreamProtocol = errors.New("portals: stream protocol violation")

type inboundChunk struct {
	chunk any
	size  int
}

// Stream is one open bidirectional stream. Safe for concurrent use.
type Stream struct {
	id        uint64
	maxCredit int
	maxFrames int
	send      func([]byte) error
	encode    func(any) ([]byte, error)

	mu         sync.Mutex
	changed    chan struct{} // closed and replaced on every state change
	sendCredit int
	sendFrames int
	recvCredit int
	recvBytes  int
	inbox      []inboundChunk
	outOpen    bool
	inOpen     bool
	cancelled  bool
	onCancel   func()
}

func newStream(id uint64, maxCredit, maxFrames int, send func([]byte) error, encode func(any) ([]byte, error)) *Stream {
	return &Stream{
		id:        id,
		maxCredit: maxCredit,
		maxFrames: maxFrames,
		send:      send,
		encode:    encode,
		changed:   make(chan struct{}),
		outOpen:   true,
		inOpen:    true,
	}
}

// ID is the stream's id, which is also the request_id of the CALL that
// opened it.
func (s *Stream) ID() uint64 { return s.id }

// notifyLocked wakes every waiter. Callers hold s.mu.
func (s *Stream) notifyLocked() {
	close(s.changed)
	s.changed = make(chan struct{})
}

// wait releases s.mu until the next state change or the deadline, then
// reacquires it. It reports false once the deadline has passed.
func (s *Stream) wait(deadline time.Time) bool {
	changed := s.changed
	s.mu.Unlock()
	defer s.mu.Lock()

	if deadline.IsZero() {
		<-changed
		return true
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return false
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case <-changed:
		return true
	case <-timer.C:
		return false
	}
}

func deadlineFor(timeout time.Duration) time.Time {
	if timeout <= 0 {
		return time.Time{}
	}
	return time.Now().Add(timeout)
}

// -- receive side -------------------------------------------------------

// initialGrant returns the bytes to grant the BEAM up front, reserving
// them as outstanding credit. Also the replenishment amount after
// consumption. Returns 0 when nothing is owed.
func (s *Stream) initialGrant() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.grantLocked()
}

func (s *Stream) grantLocked() int {
	bytes := s.maxCredit - s.recvCredit - s.recvBytes
	if bytes <= 0 {
		return 0
	}
	s.recvCredit += bytes
	return bytes
}

// recordInbound accounts for one inbound STREAM_DATA frame, failing with
// errStreamProtocol when the peer exceeded its allowance.
func (s *Stream) recordInbound(chunk any, frameSize int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case !s.inOpen:
		return fmt.Errorf("%w: STREAM_DATA after HALF_CLOSE", errStreamProtocol)
	case len(s.inbox) >= s.maxFrames:
		return fmt.Errorf("%w: queued stream frame limit exceeded", errStreamProtocol)
	case frameSize > s.recvCredit:
		return fmt.Errorf("%w: stream byte credit exceeded", errStreamProtocol)
	}
	s.recvCredit -= frameSize
	s.recvBytes += frameSize
	s.inbox = append(s.inbox, inboundChunk{chunk, frameSize})
	s.notifyLocked()
	return nil
}

// Recv blocks for the next inbound chunk. It returns io.EOF once the BEAM
// has half-closed its sending direction and every queued chunk has been
// consumed, and ErrStreamCancelled once the stream was cancelled.
// Consuming a chunk is what replenishes the BEAM's credit.
func (s *Stream) Recv() (any, error) { return s.RecvTimeout(0) }

// RecvTimeout is Recv with a timeout; a non-positive timeout waits
// forever. It returns ErrTimeout when the timeout elapses first.
func (s *Stream) RecvTimeout(timeout time.Duration) (any, error) {
	deadline := deadlineFor(timeout)
	s.mu.Lock()
	for len(s.inbox) == 0 {
		if s.cancelled {
			s.mu.Unlock()
			return nil, ErrStreamCancelled
		}
		if !s.inOpen {
			s.mu.Unlock()
			return nil, io.EOF
		}
		if !s.wait(deadline) {
			s.mu.Unlock()
			return nil, fmt.Errorf("%w: stream %d receive", ErrTimeout, s.id)
		}
	}
	next := s.inbox[0]
	s.inbox[0] = inboundChunk{}
	s.inbox = s.inbox[1:]
	s.recvBytes -= next.size
	grant := s.grantLocked()
	s.mu.Unlock()

	if grant > 0 {
		s.credit(grant, 1)
	}
	return next.chunk, nil
}

// -- send side ----------------------------------------------------------

// Send sends one chunk, blocking the calling goroutine (never the socket
// reader) until the BEAM has granted enough credit.
func (s *Stream) Send(chunk any) error { return s.SendTimeout(chunk, 0) }

// SendTimeout is Send with a timeout; a non-positive timeout waits
// forever. It returns ErrTimeout when no credit arrives in time.
func (s *Stream) SendTimeout(chunk any, timeout time.Duration) error {
	payload, err := s.encode([]any{TagStreamData, s.id, chunk})
	if err != nil {
		return err
	}
	frameSize := len(payload) + FramePrefixBytes
	if frameSize > s.maxCredit {
		return fmt.Errorf("%w: chunk of %d bytes exceeds the stream window of %d",
			errStreamProtocol, frameSize, s.maxCredit)
	}

	deadline := deadlineFor(timeout)
	s.mu.Lock()
	for {
		if s.cancelled {
			s.mu.Unlock()
			return fmt.Errorf("%w: stream %d was cancelled", ErrStreamClosed, s.id)
		}
		if !s.outOpen {
			s.mu.Unlock()
			return fmt.Errorf("%w: stream %d outbound direction is half-closed", ErrStreamClosed, s.id)
		}
		if s.sendFrames < s.maxFrames && frameSize <= s.sendCredit {
			s.sendCredit -= frameSize
			s.sendFrames++
			break
		}
		if !s.wait(deadline) {
			s.mu.Unlock()
			return fmt.Errorf("%w: stream %d send waiting for credit", ErrTimeout, s.id)
		}
	}
	s.mu.Unlock()
	return s.send(payload)
}

// HalfClose closes only this side's sending direction. Idempotent.
func (s *Stream) HalfClose() error {
	s.mu.Lock()
	if !s.outOpen || s.cancelled {
		s.mu.Unlock()
		return nil
	}
	s.outOpen = false
	s.notifyLocked()
	s.mu.Unlock()

	payload, err := s.encode([]any{TagHalfClose, s.id})
	if err != nil {
		return err
	}
	return s.send(payload)
}

// Cancelled reports whether the BEAM cancelled the stream.
func (s *Stream) Cancelled() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cancelled
}

// -- peer events --------------------------------------------------------

func (s *Stream) addSendCredit(bytes, frames int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sendCredit = min(s.sendCredit+bytes, s.maxCredit)
	s.sendFrames = max(s.sendFrames-frames, 0)
	s.notifyLocked()
}

func (s *Stream) peerHalfClosed() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.inOpen = false
	s.notifyLocked()
}

// cancel releases every piece of local state and unblocks the handler.
func (s *Stream) cancel() {
	s.mu.Lock()
	if s.cancelled {
		s.mu.Unlock()
		return
	}
	s.cancelled = true
	s.outOpen = false
	s.inOpen = false
	s.inbox = nil
	s.notifyLocked()
	onCancel := s.onCancel
	s.mu.Unlock()

	if onCancel != nil {
		onCancel()
	}
}

func (s *Stream) credit(bytes, frames int) {
	payload, err := s.encode([]any{TagCredit, s.id, bytes, frames})
	if err == nil {
		s.send(payload)
	}
}
