package portals

import (
	"errors"
	"io"
	"reflect"
	"sync"
	"testing"
	"time"
)

// Mirrors sdk/python/tests/test_streams.py: the credit window, the
// independent queued-frame cap, per-direction half-close, and
// cancellation.

const (
	testWindow    = 1024
	testMaxFrames = 4
)

type recorder struct {
	mu   sync.Mutex
	sent [][]byte
}

func (r *recorder) send(b []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, b)
	return nil
}

func (r *recorder) frames(t *testing.T) [][]any {
	t.Helper()
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([][]any, len(r.sent))
	for i, b := range r.sent {
		term, _, err := Decode(b, DefaultLimits)
		if err != nil {
			t.Fatal(err)
		}
		out[i] = term.([]any)
	}
	return out
}

func newTestStream() (*Stream, *recorder) {
	r := &recorder{}
	s := newStream(7, testWindow, testMaxFrames, r.send,
		func(term any) ([]byte, error) { return Encode(term, DefaultLimits) })
	return s, r
}

func TestInitialGrantOffersTheWholeWindowOnce(t *testing.T) {
	s, _ := newTestStream()
	if got := s.initialGrant(); got != testWindow {
		t.Fatalf("first grant %d", got)
	}
	if got := s.initialGrant(); got != 0 {
		t.Fatalf("second grant %d", got)
	}
}

func TestInboundBeyondTheGrantedWindowIsRejected(t *testing.T) {
	s, _ := newTestStream()
	s.initialGrant()
	if err := s.recordInbound("a", 512); err != nil {
		t.Fatal(err)
	}
	if err := s.recordInbound("b", 600); !errors.Is(err, errStreamProtocol) {
		t.Fatalf("got %v", err)
	}
}

func TestTinyFrameFloodHitsTheFrameLimitWhileBytesRemain(t *testing.T) {
	s, _ := newTestStream()
	s.initialGrant()
	for i := 0; i < testMaxFrames; i++ {
		if err := s.recordInbound(i, 8); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.recordInbound("one too many", 8); !errors.Is(err, errStreamProtocol) {
		t.Fatalf("got %v", err)
	}
}

func TestConsumingReplenishesExactlyWhatWasConsumed(t *testing.T) {
	s, r := newTestStream()
	s.initialGrant()
	s.recordInbound("chunk", 100)

	chunk, err := s.Recv()
	if err != nil || chunk != "chunk" {
		t.Fatalf("got %v, %v", chunk, err)
	}
	frames := r.frames(t)
	want := []any{int64(TagCredit), int64(7), int64(100), int64(1)}
	if !reflect.DeepEqual(frames[len(frames)-1], want) {
		t.Fatalf("got %#v", frames[len(frames)-1])
	}
}

func TestRecvDrainsQueuedChunksThenReturnsEOFAfterHalfClose(t *testing.T) {
	s, _ := newTestStream()
	s.initialGrant()
	s.recordInbound("last", 8)
	s.peerHalfClosed()

	if chunk, err := s.Recv(); chunk != "last" || err != nil {
		t.Fatalf("got %v, %v", chunk, err)
	}
	if _, err := s.Recv(); err != io.EOF {
		t.Fatalf("got %v", err)
	}
}

func TestInboundAfterHalfCloseIsAProtocolError(t *testing.T) {
	s, _ := newTestStream()
	s.initialGrant()
	s.peerHalfClosed()
	if err := s.recordInbound("late", 8); !errors.Is(err, errStreamProtocol) {
		t.Fatalf("got %v", err)
	}
}

func TestSendBlocksUntilCreditArrives(t *testing.T) {
	s, r := newTestStream()
	done := make(chan error, 1)
	go func() { done <- s.Send("payload") }()

	time.Sleep(50 * time.Millisecond)
	if len(r.frames(t)) != 0 {
		t.Fatal("sent without credit")
	}
	s.addSendCredit(testWindow, 0)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	want := []any{int64(TagStreamData), int64(7), "payload"}
	if got := r.frames(t)[0]; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v", got)
	}
}

func TestSendIsBoundedByTheQueuedFrameCapEvenWithBytesLeft(t *testing.T) {
	s, r := newTestStream()
	s.addSendCredit(testWindow, 0)
	for i := 0; i < testMaxFrames; i++ {
		if err := s.Send("x"); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.SendTimeout("x", 50*time.Millisecond); !errors.Is(err, ErrTimeout) {
		t.Fatalf("got %v", err)
	}
	s.addSendCredit(0, 1)
	if err := s.SendTimeout("x", time.Second); err != nil {
		t.Fatal(err)
	}
	if n := len(r.frames(t)); n != testMaxFrames+1 {
		t.Fatalf("sent %d frames", n)
	}
}

func TestRecvTimesOut(t *testing.T) {
	s, _ := newTestStream()
	if _, err := s.RecvTimeout(20 * time.Millisecond); !errors.Is(err, ErrTimeout) {
		t.Fatalf("got %v", err)
	}
}

func TestHalfCloseIsPerDirectionAndIdempotent(t *testing.T) {
	s, r := newTestStream()
	s.initialGrant()
	s.HalfClose()
	s.HalfClose()

	if err := s.Send("nope"); !errors.Is(err, ErrStreamClosed) {
		t.Fatalf("got %v", err)
	}
	// The inbound direction is still open.
	if err := s.recordInbound("still open", 8); err != nil {
		t.Fatal(err)
	}
	if chunk, _ := s.Recv(); chunk != "still open" {
		t.Fatalf("got %v", chunk)
	}

	halfCloses := 0
	for _, f := range r.frames(t) {
		if f[0] == int64(TagHalfClose) {
			halfCloses++
		}
	}
	if halfCloses != 1 {
		t.Fatalf("sent %d HALF_CLOSE frames", halfCloses)
	}
}

func TestCancelUnblocksABlockedSenderAndReceiver(t *testing.T) {
	s, _ := newTestStream()
	sendErr := make(chan error, 1)
	recvErr := make(chan error, 1)
	go func() { sendErr <- s.Send("blocked") }()
	go func() { _, err := s.Recv(); recvErr <- err }()

	time.Sleep(20 * time.Millisecond)
	s.cancel()

	if err := <-sendErr; !errors.Is(err, ErrStreamClosed) {
		t.Fatalf("send: %v", err)
	}
	if err := <-recvErr; err != ErrStreamCancelled {
		t.Fatalf("recv: %v", err)
	}
	if !s.Cancelled() {
		t.Fatal("not cancelled")
	}
}

func TestAChunkLargerThanTheWindowIsRejectedUpFront(t *testing.T) {
	s, _ := newTestStream()
	if err := s.Send(make([]byte, testWindow)); !errors.Is(err, errStreamProtocol) {
		t.Fatalf("got %v", err)
	}
}
