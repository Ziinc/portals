package portals

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"runtime"
	"strings"
	"sync"
)

// The Go worker runtime: connects to the BEAM's Unix socket, completes the
// exact-version handshake, and dispatches CALL frames to registered
// handlers concurrently.
//
//	w := portals.NewWorker(portals.Options{})
//	w.Handle("my_module", "add", func(c *portals.Call, args portals.Args) (any, error) { ... })
//	if err := w.Run(); err != nil { log.Fatal(err) }
//
// The socket reader is a dedicated goroutine independent of call execution
// (each CALL runs on its own goroutine, bounded by MaxConcurrency), so a
// slow or blocked handler can never stall reading further frames or
// responding to other in-flight calls.
//
// Fully reentrant callbacks (protocol/v1.md section 8): a handler may call
// back into the BEAM with Call.Callback, which blocks only the handler's
// own goroutine, so a nested CALL dispatched back into this same worker
// while the callback is outstanding is still served.

const (
	DefaultMaxConcurrency = 16
	DefaultMaxStreams     = 8
)

// Options configure a Worker. Zero values select the defaults.
type Options struct {
	// MaxConcurrency bounds concurrently executing unary CALLs and is
	// advertised in HELLO.
	MaxConcurrency int
	// MaxStreams bounds concurrently open streams and is advertised in
	// HELLO. Set it to -1 to advertise no streaming support.
	MaxStreams int
	// SocketPath is the Unix socket to connect to. Defaults to the last
	// command-line argument, which Portals.Connection appends.
	SocketPath string
	// Transport is "unix" (default) or "stdio" for the framed
	// stdin/stdout fallback.
	Transport string
	// ProtocolVersion overrides the version sent in HELLO, strictly so the
	// version-mismatch diagnostics can be exercised end to end. Real
	// workers leave it zero.
	ProtocolVersion int
	// Logger receives diagnostics. Logging never goes over the RPC
	// protocol; the default writes to PORTALS_LOG_FILE if set, else stderr.
	Logger func(message string)
}

// UndefinedError reports a CALL to a module/function with no registered
// handler.
type UndefinedError struct {
	Module, Function string
}

func (e *UndefinedError) Error() string {
	return fmt.Sprintf("undefined function %s.%s", e.Module, e.Function)
}

type callbackResult struct {
	ok    bool
	value any
}

type handlerKey struct{ module, function string }

// Worker is one Portals worker process's connection to the BEAM.
type Worker struct {
	opts           Options
	maxConcurrency int
	maxStreams     int
	logger         func(string)

	handlers       map[handlerKey]Handler
	streamHandlers map[handlerKey]StreamHandler

	conn   *framedConn
	limits Limits
	ctx    context.Context
	stop   context.CancelFunc
	slots  chan struct{}

	mu      sync.Mutex
	streams map[uint64]*Stream
	unary   map[uint64]context.CancelFunc

	cbMu       sync.Mutex
	callbackID uint64
	callbacks  map[uint64]chan callbackResult
}

// NewWorker creates a worker. Register handlers before calling Run.
func NewWorker(opts Options) *Worker {
	w := &Worker{
		opts:           opts,
		maxConcurrency: opts.MaxConcurrency,
		maxStreams:     opts.MaxStreams,
		logger:         opts.Logger,
		handlers:       map[handlerKey]Handler{},
		streamHandlers: map[handlerKey]StreamHandler{},
		limits:         DefaultLimits,
		streams:        map[uint64]*Stream{},
		unary:          map[uint64]context.CancelFunc{},
		callbacks:      map[uint64]chan callbackResult{},
	}
	if w.maxConcurrency <= 0 {
		w.maxConcurrency = DefaultMaxConcurrency
	}
	switch {
	case w.maxStreams == 0:
		w.maxStreams = DefaultMaxStreams
	case w.maxStreams < 0:
		w.maxStreams = 0
	}
	if w.logger == nil {
		w.logger = defaultLogger()
	}
	return w
}

func defaultLogger() func(string) {
	out := io.Writer(os.Stderr)
	if path := os.Getenv("PORTALS_LOG_FILE"); path != "" {
		if f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			out = f
		}
	}
	logger := log.New(out, "", log.LstdFlags)
	return func(message string) { logger.Println(message) }
}

// Handle registers a unary handler under the module/function names the
// BEAM will use in CALL.
func (w *Worker) Handle(module, function string, h Handler) {
	w.handlers[handlerKey{module, function}] = h
}

// HandleStream registers a streaming handler: a CALL to module.function
// opens a bidirectional stream.
func (w *Worker) HandleStream(module, function string, h StreamHandler) {
	w.streamHandlers[handlerKey{module, function}] = h
}

// Run connects, completes the handshake, and serves frames until the BEAM
// closes the connection or sends SHUTDOWN. It returns nil on a clean close.
func (w *Worker) Run() error {
	conn, err := w.connect()
	if err != nil {
		return err
	}
	w.conn = conn
	defer conn.close()

	if err := w.handshake(); err != nil {
		return err
	}

	w.ctx, w.stop = context.WithCancel(context.Background())
	w.slots = make(chan struct{}, w.maxConcurrency)
	defer w.teardown()

	for {
		payload, err := conn.recvFrame()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if w.handleFrame(payload) {
			return nil
		}
	}
}

func (w *Worker) connect() (*framedConn, error) {
	if w.opts.Transport == "stdio" {
		return stdioConn(), nil
	}
	path := w.opts.SocketPath
	if path == "" {
		if len(os.Args) < 2 {
			return nil, errors.New("portals worker: expected the socket path as the last argument")
		}
		path = os.Args[len(os.Args)-1]
	}
	return dialUnix(path)
}

// -- Handshake ------------------------------------------------------------

func (w *Worker) handshake() error {
	version := w.opts.ProtocolVersion
	if version == 0 {
		version = ProtocolVersion
	}
	runtimeName := "go" + strings.TrimPrefix(runtime.Version(), "go")
	hello := []any{TagHello, version, runtimeName, w.maxConcurrency, w.maxStreams, []any{}}
	if err := w.sendEnvelope(hello); err != nil {
		return err
	}

	payload, err := w.conn.recvFrame()
	if err != nil {
		return fmt.Errorf("portals worker: connection closed during handshake: %w", err)
	}
	term, rest, err := Decode(payload, w.limits)
	if err != nil {
		return err
	}
	envelope, ok := term.([]any)
	if !ok || len(rest) != 0 || len(envelope) < 3 {
		return errors.New("portals worker: malformed READY")
	}
	if tag, _ := toInt64(envelope[0]); tag != TagReady {
		return fmt.Errorf("portals worker: expected READY, got frame tag %v", envelope[0])
	}
	if beam, _ := toInt64(envelope[1]); beam != ProtocolVersion {
		return fmt.Errorf("portals worker: protocol version mismatch: worker=%d beam=%v",
			ProtocolVersion, envelope[1])
	}
	if limits, ok := envelope[2].(map[string]any); ok {
		w.limits = w.limits.merge(limits)
	}
	w.conn.maxFrame = w.limits.MaxFrameSize
	return nil
}

// teardown cancels everything still in flight once the connection is gone.
func (w *Worker) teardown() {
	w.stop()

	w.mu.Lock()
	streams := w.streams
	w.streams = map[uint64]*Stream{}
	w.mu.Unlock()
	for _, s := range streams {
		s.cancel()
	}

	w.cbMu.Lock()
	pending := w.callbacks
	w.callbacks = map[uint64]chan callbackResult{}
	w.cbMu.Unlock()
	for _, ch := range pending {
		ch <- callbackResult{ok: false, value: &Error{Kind: "worker_exit", Message: ErrNoWorker.Error()}}
	}
}

// -- Frame dispatch -------------------------------------------------------

// handleFrame processes one inbound frame, reporting true on SHUTDOWN.
func (w *Worker) handleFrame(payload []byte) bool {
	term, rest, err := Decode(payload, w.limits)
	if err != nil {
		w.log(fmt.Sprintf("portals worker: dropping malformed frame: %v", err))
		return false
	}
	envelope, ok := term.([]any)
	if !ok || len(envelope) == 0 || len(rest) != 0 {
		w.log("portals worker: dropping frame that is not a well-formed envelope")
		return false
	}
	tag, ok := toInt64(envelope[0])
	if !ok {
		w.log("portals worker: dropping frame with a non-integer tag")
		return false
	}
	fields := envelope[1:]
	field := func(i int) any {
		if i < len(fields) {
			return fields[i]
		}
		return nil
	}
	frameSize := len(payload) + FramePrefixBytes

	switch tag {
	case TagCall:
		w.submitCall(fields)
	case TagCancel:
		w.cancelRequest(toUint64(field(0)))
	case TagStreamData:
		w.handleStreamData(toUint64(field(0)), field(1), frameSize)
	case TagCredit:
		if s := w.findStream(toUint64(field(0))); s != nil {
			bytes, _ := toInt64(field(1))
			frames := int64(1)
			if len(fields) > 2 {
				frames, _ = toInt64(field(2))
			}
			s.addSendCredit(int(bytes), int(frames))
		}
	case TagHalfClose:
		if s := w.findStream(toUint64(field(0))); s != nil {
			s.peerHalfClosed()
		}
	case TagCallbackReturn:
		w.resolveCallback(toUint64(field(0)), callbackResult{ok: true, value: field(1)})
	case TagCallbackError:
		w.resolveCallback(toUint64(field(0)), callbackResult{ok: false, value: errorFromMap(field(1))})
	case TagPing:
		w.sendEnvelope([]any{TagPong, field(0)})
	case TagPong:
	case TagShutdown:
		return true
	default:
		w.log(fmt.Sprintf("portals worker: ignoring unsupported frame tag %d", tag))
	}
	return false
}

// -- Dispatch -------------------------------------------------------------

// submitCall routes a CALL to a unary handler, or — when its target was
// registered with HandleStream — opens a stream bound to the call's
// request_id.
func (w *Worker) submitCall(fields []any) {
	get := func(i int) any {
		if i < len(fields) {
			return fields[i]
		}
		return nil
	}
	call := &Call{worker: w, requestID: toUint64(get(0))}
	call.module, _ = get(1).(string)
	call.function, _ = get(2).(string)
	args, _ := get(3).([]any)
	call.deadlineMS, call.hasDeadline = toInt64(get(4))
	call.depth, _ = toInt64(get(5))

	key := handlerKey{call.module, call.function}
	if h, ok := w.streamHandlers[key]; ok {
		w.openStream(call, h, args)
		return
	}

	ctx, cancel := context.WithCancel(w.ctx)
	call.ctx = ctx
	w.mu.Lock()
	w.unary[call.requestID] = cancel
	w.mu.Unlock()

	go func() {
		w.slots <- struct{}{}
		value, errMap := w.invoke(func() (any, error) {
			h, ok := w.handlers[key]
			if !ok {
				return nil, &UndefinedError{call.module, call.function}
			}
			return h(call, Args(args))
		})
		<-w.slots

		w.mu.Lock()
		delete(w.unary, call.requestID)
		w.mu.Unlock()
		cancel()

		if errMap != nil {
			w.sendEnvelope([]any{TagError, call.requestID, errMap})
		} else {
			w.sendTerminal(call.requestID, value)
		}
	}()
}

func (w *Worker) openStream(call *Call, h StreamHandler, args []any) {
	if w.maxStreams == 0 {
		w.sendEnvelope([]any{TagError, call.requestID, overloadErrorMap("worker advertises no streams")})
		return
	}

	w.mu.Lock()
	if len(w.streams) >= w.maxStreams {
		w.mu.Unlock()
		w.sendEnvelope([]any{TagError, call.requestID, overloadErrorMap("max_streams exceeded")})
		return
	}
	s := newStream(call.requestID, w.limits.MaxStreamByteCredit, w.limits.MaxQueuedStreamFrames,
		w.conn.sendFrame, func(term any) ([]byte, error) { return Encode(term, w.limits) })
	ctx, cancel := context.WithCancel(w.ctx)
	call.ctx = ctx
	s.onCancel = cancel
	w.streams[call.requestID] = s
	w.mu.Unlock()

	if grant := s.initialGrant(); grant > 0 {
		w.sendEnvelope([]any{TagCredit, call.requestID, grant, 0})
	}

	go func() {
		defer cancel()
		value, errMap := w.invoke(func() (any, error) { return h(call, s, Args(args)) })
		if errMap == nil {
			s.HalfClose()
		}
		w.releaseStream(call.requestID)
		if s.Cancelled() {
			return
		}
		if errMap != nil {
			w.sendEnvelope([]any{TagError, call.requestID, errMap})
		} else {
			w.sendTerminal(call.requestID, value)
		}
	}()
}

// invoke runs a handler, mapping a returned error or a panic to an
// error_map.
func (w *Worker) invoke(fn func() (any, error)) (value any, errMap map[string]any) {
	defer func() {
		if r := recover(); r != nil {
			value, errMap = nil, panicErrorMap(r)
		}
	}()
	value, err := fn()
	if err != nil {
		return nil, errorMap(err)
	}
	return value, nil
}

// sendTerminal sends RETURN, falling back to an ERROR when the handler's
// value cannot be encoded, so the caller always gets a terminal frame.
func (w *Worker) sendTerminal(requestID uint64, value any) {
	payload, err := Encode([]any{TagReturn, requestID, value}, w.limits)
	if err != nil {
		w.sendEnvelope([]any{TagError, requestID, errorMap(fmt.Errorf("cannot encode return value: %w", err))})
		return
	}
	if err := w.conn.sendFrame(payload); err != nil {
		w.log(fmt.Sprintf("portals worker: send failed: %v", err))
	}
}

// -- Streaming ------------------------------------------------------------

func (w *Worker) findStream(id uint64) *Stream {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.streams[id]
}

func (w *Worker) releaseStream(id uint64) {
	w.mu.Lock()
	delete(w.streams, id)
	w.mu.Unlock()
}

func (w *Worker) handleStreamData(id uint64, chunk any, frameSize int) {
	s := w.findStream(id)
	if s == nil {
		return
	}
	if err := s.recordInbound(chunk, frameSize); err != nil {
		// A peer that exceeds its allowance loses only that stream.
		s.cancel()
		w.releaseStream(id)
		w.sendEnvelope([]any{TagError, id, protocolErrorMap(err.Error())})
	}
}

// cancelRequest handles CANCEL, which shares the request_id space with
// streams: it cancels the stream outright, or cancels the context of an
// in-flight unary call (cooperative, never a forced kill).
func (w *Worker) cancelRequest(id uint64) {
	w.mu.Lock()
	s := w.streams[id]
	delete(w.streams, id)
	cancel := w.unary[id]
	w.mu.Unlock()

	if s != nil {
		s.cancel()
	}
	if cancel != nil {
		cancel()
	}
}

// -- Reentrant callbacks --------------------------------------------------

func (w *Worker) callback(ctx context.Context, depth int64, module, function string, args []any) (any, error) {
	ch := make(chan callbackResult, 1)
	w.cbMu.Lock()
	w.callbackID++
	id := w.callbackID
	w.callbacks[id] = ch
	w.cbMu.Unlock()

	if err := w.sendEnvelope([]any{TagCallback, id, module, function, args, depth}); err != nil {
		w.dropCallback(id)
		return nil, err
	}

	select {
	case result := <-ch:
		if !result.ok {
			return nil, result.value.(*Error)
		}
		return result.value, nil
	case <-ctx.Done():
		w.dropCallback(id)
		return nil, ctx.Err()
	}
}

func (w *Worker) dropCallback(id uint64) {
	w.cbMu.Lock()
	delete(w.callbacks, id)
	w.cbMu.Unlock()
}

func (w *Worker) resolveCallback(id uint64, result callbackResult) {
	w.cbMu.Lock()
	ch, ok := w.callbacks[id]
	delete(w.callbacks, id)
	w.cbMu.Unlock()
	if !ok {
		w.log(fmt.Sprintf("portals worker: unknown callback_id %d in response", id))
		return
	}
	ch <- result
}

// -- Sending --------------------------------------------------------------

func (w *Worker) sendEnvelope(envelope []any) error {
	payload, err := Encode(envelope, w.limits)
	if err == nil {
		err = w.conn.sendFrame(payload)
	}
	if err != nil {
		w.log(fmt.Sprintf("portals worker: send failed: %v", err))
	}
	return err
}

func (w *Worker) log(message string) { w.logger(message) }

func toUint64(v any) uint64 {
	switch n := v.(type) {
	case uint64:
		return n
	case int64:
		if n >= 0 {
			return uint64(n)
		}
	}
	return 0
}
