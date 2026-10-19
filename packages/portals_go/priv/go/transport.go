package portals

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"sync"
)

// Length-framed transport for the Go worker side.
//
// Matches the BEAM's {:packet, 4} framing exactly: a 4-byte big-endian
// length prefix followed by that many bytes of envelope, encoded with the
// codec PORTALS_CODEC selects (wire_codec.go). A framed connection hides that framing so callers only ever see
// whole envelopes. The stdio variant is the fallback for platforms without
// Unix-socket support.

// ErrConnectionClosed is returned when the peer closes mid-frame.
var ErrConnectionClosed = errors.New("portals: connection closed")

type framedConn struct {
	r      io.Reader
	w      io.Writer
	closer io.Closer
	sendMu sync.Mutex
	// maxFrame bounds an inbound frame's declared length before anything
	// is allocated for it.
	maxFrame int
}

func dialUnix(path string) (*framedConn, error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return nil, err
	}
	return &framedConn{r: conn, w: conn, closer: conn, maxFrame: DefaultLimits.MaxFrameSize}, nil
}

func stdioConn() *framedConn {
	return &framedConn{r: os.Stdin, w: os.Stdout, maxFrame: DefaultLimits.MaxFrameSize}
}

// sendFrame writes one length-prefixed frame. Safe for concurrent use.
func (c *framedConn) sendFrame(payload []byte) error {
	frame := make([]byte, FramePrefixBytes+len(payload))
	binary.BigEndian.PutUint32(frame, uint32(len(payload)))
	copy(frame[FramePrefixBytes:], payload)

	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	_, err := c.w.Write(frame)
	return err
}

// recvFrame reads one frame. It returns io.EOF on a clean close between
// frames and ErrConnectionClosed on a close mid-frame. Only the reader
// goroutine calls it.
func (c *framedConn) recvFrame() ([]byte, error) {
	var header [FramePrefixBytes]byte
	if _, err := io.ReadFull(c.r, header[:]); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, io.EOF
		}
		return nil, ErrConnectionClosed
	}
	length := binary.BigEndian.Uint32(header[:])
	if c.maxFrame > 0 && int64(length) > int64(c.maxFrame) {
		return nil, codecErr("max_size_exceeded", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(c.r, payload); err != nil {
		return nil, ErrConnectionClosed
	}
	return payload, nil
}

func (c *framedConn) close() {
	if c.closer != nil {
		c.closer.Close()
	}
}
