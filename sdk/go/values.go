package portals

import (
	"encoding/hex"
	"fmt"
)

// Host-language representations of the Erlang-specific value extensions
// (protocol/v1.md section 5.1). Everything else maps onto plain Go types:
//
//	nil                  <-> nil
//	true/false           <-> bool
//	integer              <-> int64 (uint64 above math.MaxInt64, *big.Int
//	                         beyond 64 bits)
//	float                <-> float64
//	str                  <-> string
//	bin                  <-> []byte
//	array                <-> []any
//	string-keyed map     <-> map[string]any
//
// On encode, any Go integer, float, slice/array, or string-keyed map type is
// accepted.

// Tuple is an Erlang tuple. A []any is a list, so tuples need their own type
// to round-trip back to the BEAM as tuples.
type Tuple []any

// Atom is an Erlang atom. Go has no BEAM atom table, so section 5.3's
// unsafe-atom concern does not apply and atoms decode to their text.
type Atom string

// Pid is an opaque local or distributed Erlang PID. A trusted worker may
// store and echo it back (e.g. as a MESSAGE target) but must never attempt
// to construct or interpret its bytes. Pids are comparable.
type Pid struct{ raw string }

func (p Pid) String() string { return "#Pid<" + hex.EncodeToString([]byte(p.raw)) + ">" }

// Reference is an opaque Erlang reference, with the same opacity rules as
// Pid.
type Reference struct{ raw string }

func (r Reference) String() string {
	return "#Reference<" + hex.EncodeToString([]byte(r.raw)) + ">"
}

// ImproperList is an Erlang improper list [Items... | Tail], which a Go
// slice cannot represent.
type ImproperList struct {
	Items []any
	Tail  any
}

func (l ImproperList) String() string { return fmt.Sprintf("%v | %v", l.Items, l.Tail) }
