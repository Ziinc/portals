package portals

import (
	"encoding/binary"
	"fmt"
	"math"
	"math/big"
	"reflect"
	"unicode/utf8"
)

// Pure-Go MessagePack codec implementing the exact subset used by the
// Portals v1 wire protocol, including the Erlang-value extensions
// (protocol/v1.md section 5). Deliberately dependency-free, like the other
// bundled SDKs, so the ext-type semantics stay byte-for-byte identical to
// lib/portals/codec/message_pack.ex.

// Portals extension type codes (protocol/v1.md section 5.1).
const (
	extTuple        = 0
	extAtom         = 1
	extPid          = 2
	extReference    = 3
	extBigint       = 4
	extImproperList = 5
)

// Integers below this bound are encoded as the bigint extension, matching
// the reference Elixir codec.
const intLowerBound = -1_099_511_627_776

var (
	bigUint64Limit = new(big.Int).Lsh(big.NewInt(1), 64)
	bigLowerBound  = big.NewInt(intLowerBound)
)

// CodecError is returned for every codec-level failure, on encode and decode
// alike. Reason is the protocol's error class ("truncated",
// "invalid_encoding", "max_length_exceeded", ...).
type CodecError struct {
	Reason string
	Detail any
}

func (e *CodecError) Error() string {
	return fmt.Sprintf("portals codec: %s (%v)", e.Reason, e.Detail)
}

func codecErr(reason string, detail any) *CodecError {
	return &CodecError{Reason: reason, Detail: detail}
}

// Encode encodes one frame envelope (or any term) to bytes, enforcing
// limits.
func Encode(term any, limits Limits) ([]byte, error) {
	e := encoder{limits: limits}
	if err := e.encode(term, 0); err != nil {
		return nil, err
	}
	if len(e.buf) > limits.MaxFrameSize {
		return nil, codecErr("max_size_exceeded", len(e.buf))
	}
	return e.buf, nil
}

// Decode decodes one term from data, returning it and any trailing bytes.
func Decode(data []byte, limits Limits) (term any, rest []byte, err error) {
	if len(data) > limits.MaxFrameSize {
		return nil, nil, codecErr("max_size_exceeded", len(data))
	}
	d := decoder{data: data, limits: limits}
	term, pos, err := d.decode(0, 0)
	if err != nil {
		return nil, nil, err
	}
	return term, data[pos:], nil
}

// -- Encoding -----------------------------------------------------------

type encoder struct {
	buf    []byte
	limits Limits
}

func (e *encoder) byte1(b byte) { e.buf = append(e.buf, b) }

func (e *encoder) checkDepth(depth int) error {
	if depth > e.limits.MaxNestingDepth {
		return codecErr("max_depth_exceeded", depth)
	}
	return nil
}

func (e *encoder) checkLength(n int) error {
	if n > e.limits.MaxCollectionLength {
		return codecErr("max_length_exceeded", n)
	}
	return nil
}

func (e *encoder) encode(term any, depth int) error {
	if err := e.checkDepth(depth); err != nil {
		return err
	}

	switch v := term.(type) {
	case nil:
		e.byte1(0xC0)
	case bool:
		if v {
			e.byte1(0xC3)
		} else {
			e.byte1(0xC2)
		}
	case int:
		e.encodeInt(int64(v))
	case int8:
		e.encodeInt(int64(v))
	case int16:
		e.encodeInt(int64(v))
	case int32:
		e.encodeInt(int64(v))
	case int64:
		e.encodeInt(v)
	case uint:
		e.encodeUint(uint64(v))
	case uint8:
		e.encodeUint(uint64(v))
	case uint16:
		e.encodeUint(uint64(v))
	case uint32:
		e.encodeUint(uint64(v))
	case uint64:
		e.encodeUint(v)
	case *big.Int:
		e.encodeBig(v)
	case big.Int:
		e.encodeBig(&v)
	case float64:
		e.encodeFloat(v)
	case float32:
		e.encodeFloat(float64(v))
	case string:
		e.encodeStr(v)
	case []byte:
		e.encodeBin(v)
	case Atom:
		e.encodeExt(extAtom, []byte(v))
	case Pid:
		e.encodeExt(extPid, []byte(v.raw))
	case Reference:
		e.encodeExt(extReference, []byte(v.raw))
	case Tuple:
		if err := e.checkLength(len(v)); err != nil {
			return err
		}
		payload, err := e.sub(func(s *encoder) error { return s.encodeArray([]any(v), depth+1) })
		if err != nil {
			return err
		}
		e.encodeExt(extTuple, payload)
	case ImproperList:
		payload, err := e.sub(func(s *encoder) error {
			return s.encodeArray([]any{v.Items, v.Tail}, depth+1)
		})
		if err != nil {
			return err
		}
		e.encodeExt(extImproperList, payload)
	case []any:
		if err := e.checkLength(len(v)); err != nil {
			return err
		}
		return e.encodeArray(v, depth+1)
	case map[string]any:
		if err := e.checkLength(len(v)); err != nil {
			return err
		}
		e.mapHeader(len(v))
		for key, value := range v {
			e.encodeStr(key)
			if err := e.encode(value, depth+1); err != nil {
				return err
			}
		}
	case *Error:
		return e.encode(v.toMap(), depth)
	default:
		return e.encodeReflect(term, depth)
	}
	return nil
}

// encodeReflect handles named and composite types the fast path does not:
// typed slices/arrays, string-keyed maps of any value type, and named
// scalar types.
func (e *encoder) encodeReflect(term any, depth int) error {
	rv := reflect.ValueOf(term)
	switch rv.Kind() {
	case reflect.Bool:
		return e.encode(rv.Bool(), depth)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		e.encodeInt(rv.Int())
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		e.encodeUint(rv.Uint())
	case reflect.Float32, reflect.Float64:
		e.encodeFloat(rv.Float())
	case reflect.String:
		e.encodeStr(rv.String())
	case reflect.Pointer, reflect.Interface:
		if rv.IsNil() {
			e.byte1(0xC0)
			return nil
		}
		return e.encode(rv.Elem().Interface(), depth)
	case reflect.Slice, reflect.Array:
		if rv.Kind() == reflect.Slice && rv.IsNil() {
			e.arrayHeader(0)
			return nil
		}
		if rv.Type().Elem().Kind() == reflect.Uint8 {
			b := make([]byte, rv.Len())
			reflect.Copy(reflect.ValueOf(b), rv)
			e.encodeBin(b)
			return nil
		}
		n := rv.Len()
		if err := e.checkLength(n); err != nil {
			return err
		}
		e.arrayHeader(n)
		for i := 0; i < n; i++ {
			if err := e.encode(rv.Index(i).Interface(), depth+1); err != nil {
				return err
			}
		}
	case reflect.Map:
		if rv.Type().Key().Kind() != reflect.String {
			return codecErr("invalid_encoding", "map keys must be strings, got "+rv.Type().Key().String())
		}
		if err := e.checkLength(rv.Len()); err != nil {
			return err
		}
		e.mapHeader(rv.Len())
		iter := rv.MapRange()
		for iter.Next() {
			e.encodeStr(iter.Key().String())
			if err := e.encode(iter.Value().Interface(), depth+1); err != nil {
				return err
			}
		}
	default:
		return codecErr("invalid_encoding", fmt.Sprintf("unsupported type %T", term))
	}
	return nil
}

// sub encodes into a fresh buffer, for extension payloads.
func (e *encoder) sub(fn func(*encoder) error) ([]byte, error) {
	s := encoder{limits: e.limits}
	if err := fn(&s); err != nil {
		return nil, err
	}
	return s.buf, nil
}

func (e *encoder) encodeArray(items []any, depth int) error {
	e.arrayHeader(len(items))
	for _, item := range items {
		if err := e.encode(item, depth); err != nil {
			return err
		}
	}
	return nil
}

func (e *encoder) arrayHeader(n int) {
	switch {
	case n < 16:
		e.byte1(0x90 | byte(n))
	case n < 65536:
		e.byte1(0xDC)
		e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(n))
	default:
		e.byte1(0xDD)
		e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(n))
	}
}

func (e *encoder) mapHeader(n int) {
	switch {
	case n < 16:
		e.byte1(0x80 | byte(n))
	case n < 65536:
		e.byte1(0xDE)
		e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(n))
	default:
		e.byte1(0xDF)
		e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(n))
	}
}

func (e *encoder) encodeStr(s string) {
	n := len(s)
	switch {
	case n < 32:
		e.byte1(0xA0 | byte(n))
	case n < 256:
		e.buf = append(e.buf, 0xD9, byte(n))
	case n < 65536:
		e.byte1(0xDA)
		e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(n))
	default:
		e.byte1(0xDB)
		e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(n))
	}
	e.buf = append(e.buf, s...)
}

func (e *encoder) encodeBin(b []byte) {
	n := len(b)
	switch {
	case n < 256:
		e.buf = append(e.buf, 0xC4, byte(n))
	case n < 65536:
		e.byte1(0xC5)
		e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(n))
	default:
		e.byte1(0xC6)
		e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(n))
	}
	e.buf = append(e.buf, b...)
}

func (e *encoder) encodeFloat(f float64) {
	e.byte1(0xCB)
	e.buf = binary.BigEndian.AppendUint64(e.buf, math.Float64bits(f))
}

// encodeInt uses the smallest MessagePack integer encoding, exactly as the
// reference Elixir codec does (including its bigint lower bound).
func (e *encoder) encodeInt(n int64) {
	switch {
	case n >= 0:
		e.encodeUint(uint64(n))
	case n < intLowerBound:
		e.encodeBig(big.NewInt(n))
	case n >= -32:
		e.byte1(byte(0xE0 | (n + 32)))
	case n >= math.MinInt8:
		e.buf = append(e.buf, 0xD0, byte(int8(n)))
	case n >= math.MinInt16:
		e.byte1(0xD1)
		e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(int16(n)))
	case n >= math.MinInt32:
		e.byte1(0xD2)
		e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(int32(n)))
	default:
		e.byte1(0xD3)
		e.buf = binary.BigEndian.AppendUint64(e.buf, uint64(n))
	}
}

func (e *encoder) encodeUint(n uint64) {
	switch {
	case n < 128:
		e.byte1(byte(n))
	case n < 256:
		e.buf = append(e.buf, 0xCC, byte(n))
	case n < 65536:
		e.byte1(0xCD)
		e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(n))
	case n < 4294967296:
		e.byte1(0xCE)
		e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(n))
	default:
		e.byte1(0xCF)
		e.buf = binary.BigEndian.AppendUint64(e.buf, n)
	}
}

func (e *encoder) encodeBig(n *big.Int) {
	if n.Cmp(bigLowerBound) >= 0 && n.Cmp(bigUint64Limit) < 0 {
		if n.IsInt64() {
			e.encodeInt(n.Int64())
		} else {
			e.encodeUint(n.Uint64())
		}
		return
	}
	var sign byte
	if n.Sign() < 0 {
		sign = 1
	}
	magnitude := new(big.Int).Abs(n).Bytes()
	if len(magnitude) == 0 {
		magnitude = []byte{0}
	}
	e.encodeExt(extBigint, append([]byte{sign}, magnitude...))
}

func (e *encoder) encodeExt(code byte, payload []byte) {
	n := len(payload)
	switch n {
	case 1:
		e.buf = append(e.buf, 0xD4, code)
	case 2:
		e.buf = append(e.buf, 0xD5, code)
	case 4:
		e.buf = append(e.buf, 0xD6, code)
	case 8:
		e.buf = append(e.buf, 0xD7, code)
	case 16:
		e.buf = append(e.buf, 0xD8, code)
	default:
		switch {
		case n < 256:
			e.buf = append(e.buf, 0xC7, byte(n), code)
		case n < 65536:
			e.byte1(0xC8)
			e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(n))
			e.byte1(code)
		default:
			e.byte1(0xC9)
			e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(n))
			e.byte1(code)
		}
	}
	e.buf = append(e.buf, payload...)
}

// -- Decoding -----------------------------------------------------------

type decoder struct {
	data   []byte
	limits Limits
}

// need fails with "truncated" unless count bytes are available at pos.
func (d *decoder) need(pos, count int) error {
	if len(d.data)-pos < count {
		return codecErr("truncated", len(d.data)-pos)
	}
	return nil
}

// uintAt reads a size-byte big-endian unsigned integer at pos.
func (d *decoder) uintAt(pos, size int) (uint64, error) {
	if err := d.need(pos, size); err != nil {
		return 0, err
	}
	b := d.data[pos : pos+size]
	switch size {
	case 1:
		return uint64(b[0]), nil
	case 2:
		return uint64(binary.BigEndian.Uint16(b)), nil
	case 4:
		return uint64(binary.BigEndian.Uint32(b)), nil
	default:
		return binary.BigEndian.Uint64(b), nil
	}
}

// decode returns the term at pos and the position just after it.
func (d *decoder) decode(pos, depth int) (any, int, error) {
	if depth > d.limits.MaxNestingDepth {
		return nil, 0, codecErr("max_depth_exceeded", depth)
	}
	if err := d.need(pos, 1); err != nil {
		return nil, 0, err
	}
	b0 := d.data[pos]

	switch {
	case b0 <= 0x7F:
		return int64(b0), pos + 1, nil
	case b0 >= 0xE0:
		return int64(int8(b0)), pos + 1, nil
	case b0 >= 0xA0 && b0 <= 0xBF:
		return d.decodeStr(pos+1, int(b0&0x1F))
	case b0 >= 0x90 && b0 <= 0x9F:
		return d.decodeArray(pos+1, int(b0&0x0F), depth)
	case b0 >= 0x80 && b0 <= 0x8F:
		return d.decodeMap(pos+1, int(b0&0x0F), depth)
	}

	switch b0 {
	case 0xC0:
		return nil, pos + 1, nil
	case 0xC2:
		return false, pos + 1, nil
	case 0xC3:
		return true, pos + 1, nil
	case 0xCC, 0xCD, 0xCE, 0xCF:
		size := 1 << (b0 - 0xCC)
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		if n > math.MaxInt64 {
			return n, pos + 1 + size, nil
		}
		return int64(n), pos + 1 + size, nil
	case 0xD0, 0xD1, 0xD2, 0xD3:
		size := 1 << (b0 - 0xD0)
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		var v int64
		switch size {
		case 1:
			v = int64(int8(n))
		case 2:
			v = int64(int16(n))
		case 4:
			v = int64(int32(n))
		default:
			v = int64(n)
		}
		return v, pos + 1 + size, nil
	case 0xCB:
		n, err := d.uintAt(pos+1, 8)
		if err != nil {
			return nil, 0, err
		}
		return math.Float64frombits(n), pos + 9, nil
	case 0xC4, 0xC5, 0xC6:
		size := 1 << (b0 - 0xC4)
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		start := pos + 1 + size
		if err := d.need(start, int(n)); err != nil {
			return nil, 0, err
		}
		out := make([]byte, n)
		copy(out, d.data[start:])
		return out, start + int(n), nil
	case 0xD9, 0xDA, 0xDB:
		size := 1 << (b0 - 0xD9)
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		return d.decodeStr(pos+1+size, int(n))
	case 0xDC, 0xDD:
		size := 2 << (b0 - 0xDC)
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		return d.decodeArray(pos+1+size, int(n), depth)
	case 0xDE, 0xDF:
		size := 2 << (b0 - 0xDE)
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		return d.decodeMap(pos+1+size, int(n), depth)
	case 0xD4, 0xD5, 0xD6, 0xD7, 0xD8:
		return d.decodeExtAt(pos+1, 1<<(b0-0xD4), depth)
	case 0xC7, 0xC8, 0xC9:
		size := 1 << (b0 - 0xC7)
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		return d.decodeExtAt(pos+1+size, int(n), depth)
	}

	return nil, 0, codecErr("invalid_encoding", b0)
}

func (d *decoder) decodeStr(start, n int) (any, int, error) {
	if err := d.need(start, n); err != nil {
		return nil, 0, err
	}
	return string(d.data[start : start+n]), start + n, nil
}

func (d *decoder) decodeArray(pos, count, depth int) (any, int, error) {
	if count > d.limits.MaxCollectionLength {
		return nil, 0, codecErr("max_length_exceeded", count)
	}
	items := make([]any, count)
	for i := range items {
		item, next, err := d.decode(pos, depth+1)
		if err != nil {
			return nil, 0, err
		}
		items[i], pos = item, next
	}
	return items, pos, nil
}

func (d *decoder) decodeMap(pos, count, depth int) (any, int, error) {
	if count > d.limits.MaxCollectionLength {
		return nil, 0, codecErr("max_length_exceeded", count)
	}
	result := make(map[string]any, count)
	for i := 0; i < count; i++ {
		key, next, err := d.decode(pos, depth+1)
		if err != nil {
			return nil, 0, err
		}
		value, next, err := d.decode(next, depth+1)
		if err != nil {
			return nil, 0, err
		}
		text, ok := key.(string)
		if !ok {
			return nil, 0, codecErr("invalid_encoding", fmt.Sprintf("non-string map key %T", key))
		}
		result[text], pos = value, next
	}
	return result, pos, nil
}

// decodeExtAt decodes an extension whose type byte is at typePos and whose
// payload of size bytes follows it.
func (d *decoder) decodeExtAt(typePos, size, depth int) (any, int, error) {
	if err := d.need(typePos, 1+size); err != nil {
		return nil, 0, err
	}
	code := int8(d.data[typePos])
	payload := d.data[typePos+1 : typePos+1+size]
	term, err := d.decodeExt(code, payload, depth)
	if err != nil {
		return nil, 0, err
	}
	return term, typePos + 1 + size, nil
}

func (d *decoder) decodeExt(code int8, payload []byte, depth int) (any, error) {
	switch code {
	case extBigint:
		if len(payload) < 1 || payload[0] > 1 {
			return nil, codecErr("invalid_extension", "bigint")
		}
		n := new(big.Int).SetBytes(payload[1:])
		if payload[0] == 1 {
			n.Neg(n)
		}
		if n.IsInt64() {
			return n.Int64(), nil
		}
		return n, nil
	case extAtom:
		if !utf8.Valid(payload) {
			return nil, codecErr("invalid_extension", "atom")
		}
		return Atom(payload), nil
	case extPid:
		return Pid{raw: string(payload)}, nil
	case extReference:
		return Reference{raw: string(payload)}, nil
	case extTuple:
		sub := decoder{data: payload, limits: d.limits}
		items, pos, err := sub.decode(0, depth+1)
		if err != nil {
			return nil, err
		}
		list, ok := items.([]any)
		if !ok || pos != len(payload) {
			return nil, codecErr("invalid_extension", "tuple")
		}
		return Tuple(list), nil
	case extImproperList:
		sub := decoder{data: payload, limits: d.limits}
		pair, pos, err := sub.decode(0, depth+1)
		if err != nil {
			return nil, err
		}
		list, ok := pair.([]any)
		if !ok || len(list) != 2 || pos != len(payload) {
			return nil, codecErr("invalid_extension", "improper_list")
		}
		items, ok := list[0].([]any)
		if !ok {
			return nil, codecErr("invalid_extension", "improper_list")
		}
		return ImproperList{Items: items, Tail: list[1]}, nil
	default:
		return nil, codecErr("invalid_extension", code)
	}
}

// toInt64 converts any decoded or native Go integer to int64.
func toInt64(v any) (int64, bool) {
	switch n := v.(type) {
	case int64:
		return n, true
	case int:
		return int64(n), true
	case int32:
		return int64(n), true
	case uint64:
		if n <= math.MaxInt64 {
			return int64(n), true
		}
	case uint32:
		return int64(n), true
	case uint:
		if uint64(n) <= math.MaxInt64 {
			return int64(n), true
		}
	}
	return 0, false
}
