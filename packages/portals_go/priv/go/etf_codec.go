package portals

import (
	"encoding/binary"
	"fmt"
	"math"
	"math/big"
	"reflect"
	"strconv"
	"unicode/utf8"
)

// Pure-Go codec for the Erlang External Term Format (protocol/v1.md section
// 5.4), the Go side of lib/portals/codec/etf.ex and the default wire codec
// (see wire_codec.go). Values map to exactly the Go types the MessagePack
// codec produces:
//
//   - binaries are string (UTF-8), and %Portals.Codec.Bin{} structs are
//     []byte (and []byte encodes as that struct);
//   - the atoms nil, true and false are nil, true and false, and other
//     atoms are Atom;
//   - maps are map[string]any: atom keys become their name and integer
//     keys their decimal text, as under MessagePack;
//   - tuples are Tuple, improper lists are ImproperList, and charlists
//     (STRING_EXT) are []any of int64;
//   - PIDs and references are opaque Pid / Reference holding their ETF
//     bytes (tag included), which are written back verbatim.

// ETF tags.
const (
	etfVersion        = 131
	etfNewFloat       = 70
	etfNewPid         = 88
	etfNewerReference = 90
	etfSmallInteger   = 97
	etfInteger        = 98
	etfAtom           = 100
	etfPid            = 103
	etfSmallTuple     = 104
	etfLargeTuple     = 105
	etfNil            = 106
	etfString         = 107
	etfList           = 108
	etfBinary         = 109
	etfSmallBig       = 110
	etfLargeBig       = 111
	etfNewReference   = 114
	etfSmallAtom      = 115
	etfMap            = 116
	etfAtomUTF8       = 118
	etfSmallAtomUTF8  = 119
)

const (
	binStructName = "Elixir.Portals.Codec.Bin"
	binStructKey  = "__struct__"
	binDataKey    = "data"
)

// etfBinPrefix is how []byte is encoded: %Portals.Codec.Bin{data: ...}, up
// to the data binary itself.
var etfBinPrefix = func() []byte {
	b := []byte{etfMap, 0, 0, 0, 2}
	for _, atom := range []string{binStructKey, binStructName, binDataKey} {
		b = append(b, etfSmallAtomUTF8, byte(len(atom)))
		b = append(b, atom...)
	}
	return b
}()

// EncodeETF encodes one frame envelope (or any term) to ETF bytes,
// version byte included, enforcing limits.
func EncodeETF(term any, limits Limits) ([]byte, error) {
	e := etfEncoder{buf: []byte{etfVersion}, limits: limits}
	if err := e.encode(term, 0); err != nil {
		return nil, err
	}
	if len(e.buf) > limits.MaxFrameSize {
		return nil, codecErr("max_size_exceeded", len(e.buf))
	}
	return e.buf, nil
}

// DecodeETF decodes one ETF term from data, returning it and any trailing
// bytes.
func DecodeETF(data []byte, limits Limits) (term any, rest []byte, err error) {
	if len(data) > limits.MaxFrameSize {
		return nil, nil, codecErr("max_size_exceeded", len(data))
	}
	if len(data) == 0 {
		return nil, nil, codecErr("truncated", 0)
	}
	if data[0] != etfVersion {
		return nil, nil, codecErr("invalid_encoding", data[0])
	}
	d := etfDecoder{data: data, limits: limits}
	term, pos, err := d.decode(1, 0)
	if err != nil {
		return nil, nil, err
	}
	return term, data[pos:], nil
}

// -- Encoding -----------------------------------------------------------

type etfEncoder struct {
	buf    []byte
	limits Limits
}

func (e *etfEncoder) byte1(b byte) { e.buf = append(e.buf, b) }

func (e *etfEncoder) uint32(n int) { e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(n)) }

func (e *etfEncoder) checkDepth(depth int) error {
	if depth > e.limits.MaxNestingDepth {
		return codecErr("max_depth_exceeded", depth)
	}
	return nil
}

func (e *etfEncoder) checkLength(n int) error {
	if n > e.limits.MaxCollectionLength {
		return codecErr("max_length_exceeded", n)
	}
	return nil
}

func (e *etfEncoder) encode(term any, depth int) error {
	if err := e.checkDepth(depth); err != nil {
		return err
	}

	switch v := term.(type) {
	case nil:
		e.encodeAtom("nil")
	case bool:
		if v {
			e.encodeAtom("true")
		} else {
			e.encodeAtom("false")
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
		e.encodeBinary(v)
	case []byte:
		e.encodeBin(v)
	case Atom:
		e.encodeAtom(string(v))
	case Pid:
		return e.encodeOpaque(v.raw, "pid", etfNewPid, etfPid)
	case Reference:
		return e.encodeOpaque(v.raw, "reference", etfNewerReference, etfNewReference)
	case Tuple:
		if err := e.checkLength(len(v)); err != nil {
			return err
		}
		if len(v) < 256 {
			e.buf = append(e.buf, etfSmallTuple, byte(len(v)))
		} else {
			e.byte1(etfLargeTuple)
			e.uint32(len(v))
		}
		return e.encodeItems(v, depth+1)
	case ImproperList:
		if err := e.checkLength(len(v.Items)); err != nil {
			return err
		}
		e.byte1(etfList)
		e.uint32(len(v.Items))
		if err := e.encodeItems(v.Items, depth+1); err != nil {
			return err
		}
		return e.encode(v.Tail, depth+1)
	case []any:
		if err := e.checkLength(len(v)); err != nil {
			return err
		}
		e.listHeader(len(v))
		if err := e.encodeItems(v, depth+1); err != nil {
			return err
		}
		e.listEnd()
	case map[string]any:
		if err := e.checkLength(len(v)); err != nil {
			return err
		}
		e.byte1(etfMap)
		e.uint32(len(v))
		for key, value := range v {
			e.encodeBinary(key)
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
func (e *etfEncoder) encodeReflect(term any, depth int) error {
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
		e.encodeBinary(rv.String())
	case reflect.Pointer, reflect.Interface:
		if rv.IsNil() {
			e.encodeAtom("nil")
			return nil
		}
		return e.encode(rv.Elem().Interface(), depth)
	case reflect.Slice, reflect.Array:
		if rv.Kind() == reflect.Slice && rv.IsNil() {
			e.byte1(etfNil)
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
		e.listHeader(n)
		for i := 0; i < n; i++ {
			if err := e.encode(rv.Index(i).Interface(), depth+1); err != nil {
				return err
			}
		}
		e.listEnd()
	case reflect.Map:
		if rv.Type().Key().Kind() != reflect.String {
			return codecErr("invalid_encoding", "map keys must be strings, got "+rv.Type().Key().String())
		}
		if err := e.checkLength(rv.Len()); err != nil {
			return err
		}
		e.byte1(etfMap)
		e.uint32(rv.Len())
		iter := rv.MapRange()
		for iter.Next() {
			e.encodeBinary(iter.Key().String())
			if err := e.encode(iter.Value().Interface(), depth+1); err != nil {
				return err
			}
		}
	default:
		return codecErr("invalid_encoding", fmt.Sprintf("unsupported type %T", term))
	}
	return nil
}

func (e *etfEncoder) encodeItems(items []any, depth int) error {
	for _, item := range items {
		if err := e.encode(item, depth); err != nil {
			return err
		}
	}
	return nil
}

// listHeader starts a proper list of n elements: NIL_EXT alone when empty.
func (e *etfEncoder) listHeader(n int) {
	if n > 0 {
		e.byte1(etfList)
		e.uint32(n)
	}
}

// listEnd closes a proper list with its NIL_EXT tail.
func (e *etfEncoder) listEnd() { e.byte1(etfNil) }

func (e *etfEncoder) encodeAtom(name string) {
	if len(name) < 256 {
		e.buf = append(e.buf, etfSmallAtomUTF8, byte(len(name)))
	} else {
		e.byte1(etfAtomUTF8)
		e.buf = binary.BigEndian.AppendUint16(e.buf, uint16(len(name)))
	}
	e.buf = append(e.buf, name...)
}

func (e *etfEncoder) encodeBinary(s string) {
	e.byte1(etfBinary)
	e.uint32(len(s))
	e.buf = append(e.buf, s...)
}

func (e *etfEncoder) encodeBin(b []byte) {
	e.buf = append(e.buf, etfBinPrefix...)
	e.byte1(etfBinary)
	e.uint32(len(b))
	e.buf = append(e.buf, b...)
}

func (e *etfEncoder) encodeFloat(f float64) {
	e.byte1(etfNewFloat)
	e.buf = binary.BigEndian.AppendUint64(e.buf, math.Float64bits(f))
}

// encodeOpaque writes a PID's or reference's stored ETF bytes verbatim,
// refusing ones that did not come from an ETF decode.
func (e *etfEncoder) encodeOpaque(raw, kind string, tags ...byte) error {
	if raw != "" {
		for _, tag := range tags {
			if raw[0] == tag {
				e.buf = append(e.buf, raw...)
				return nil
			}
		}
	}
	return codecErr("invalid_encoding", "not an ETF "+kind)
}

func (e *etfEncoder) encodeInt(n int64) {
	switch {
	case n >= 0 && n < 256:
		e.buf = append(e.buf, etfSmallInteger, byte(n))
	case n >= math.MinInt32 && n <= math.MaxInt32:
		e.byte1(etfInteger)
		e.buf = binary.BigEndian.AppendUint32(e.buf, uint32(int32(n)))
	case n < 0:
		// Two's complement: correct for math.MinInt64 too.
		e.encodeBigDigits(1, uint64(-n))
	default:
		e.encodeBigDigits(0, uint64(n))
	}
}

func (e *etfEncoder) encodeUint(n uint64) {
	if n <= math.MaxInt64 {
		e.encodeInt(int64(n))
		return
	}
	e.encodeBigDigits(0, n)
}

func (e *etfEncoder) encodeBigDigits(sign byte, magnitude uint64) {
	var digits []byte
	for ; magnitude > 0; magnitude >>= 8 {
		digits = append(digits, byte(magnitude))
	}
	e.encodeBigBytes(sign, digits)
}

func (e *etfEncoder) encodeBig(n *big.Int) {
	if n.IsInt64() {
		e.encodeInt(n.Int64())
		return
	}
	var sign byte
	if n.Sign() < 0 {
		sign = 1
	}
	// big.Int.Bytes is big-endian; ETF digits are least significant first.
	digits := new(big.Int).Abs(n).Bytes()
	for i, j := 0, len(digits)-1; i < j; i, j = i+1, j-1 {
		digits[i], digits[j] = digits[j], digits[i]
	}
	e.encodeBigBytes(sign, digits)
}

// encodeBigBytes writes SMALL_BIG_EXT (LARGE_BIG_EXT past 255 digit
// bytes): sign byte, then the little-endian magnitude.
func (e *etfEncoder) encodeBigBytes(sign byte, digits []byte) {
	if len(digits) < 256 {
		e.buf = append(e.buf, etfSmallBig, byte(len(digits)))
	} else {
		e.byte1(etfLargeBig)
		e.uint32(len(digits))
	}
	e.byte1(sign)
	e.buf = append(e.buf, digits...)
}

// -- Decoding -----------------------------------------------------------

type etfDecoder struct {
	data   []byte
	limits Limits
}

// rawBinary is a BINARY_EXT under an atom `data` key, kept as bytes until
// its map is known to be (or not to be) a %Portals.Codec.Bin{}.
type rawBinary []byte

// need fails with "truncated" unless count bytes are available at pos.
func (d *etfDecoder) need(pos int, count uint64) error {
	if pos > len(d.data) || uint64(len(d.data)-pos) < count {
		return codecErr("truncated", len(d.data))
	}
	return nil
}

// uintAt reads a size-byte big-endian unsigned integer at pos.
func (d *etfDecoder) uintAt(pos, size int) (uint64, error) {
	if err := d.need(pos, uint64(size)); err != nil {
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

func (d *etfDecoder) checkLength(n uint64) error {
	if n > uint64(d.limits.MaxCollectionLength) {
		return codecErr("max_length_exceeded", n)
	}
	return nil
}

// decode returns the term at pos and the position just after it.
func (d *etfDecoder) decode(pos, depth int) (any, int, error) {
	if depth > d.limits.MaxNestingDepth {
		return nil, 0, codecErr("max_depth_exceeded", depth)
	}
	tag, err := d.uintAt(pos, 1)
	if err != nil {
		return nil, 0, err
	}

	switch tag {
	case etfSmallInteger:
		n, err := d.uintAt(pos+1, 1)
		if err != nil {
			return nil, 0, err
		}
		return int64(n), pos + 2, nil
	case etfInteger:
		n, err := d.uintAt(pos+1, 4)
		if err != nil {
			return nil, 0, err
		}
		return int64(int32(n)), pos + 5, nil
	case etfNewFloat:
		n, err := d.uintAt(pos+1, 8)
		if err != nil {
			return nil, 0, err
		}
		return math.Float64frombits(n), pos + 9, nil
	case etfSmallAtomUTF8, etfSmallAtom, etfAtomUTF8, etfAtom:
		name, next, err := d.decodeAtom(pos)
		if err != nil {
			return nil, 0, err
		}
		switch name {
		case "nil":
			return nil, next, nil
		case "true":
			return true, next, nil
		case "false":
			return false, next, nil
		}
		return Atom(name), next, nil
	case etfBinary:
		raw, next, err := d.decodeBinary(pos)
		if err != nil {
			return nil, 0, err
		}
		text, err := binaryText(raw)
		return text, next, err
	case etfNil:
		return []any{}, pos + 1, nil
	case etfList:
		return d.decodeList(pos, depth)
	case etfString:
		n, err := d.uintAt(pos+1, 2)
		if err != nil {
			return nil, 0, err
		}
		if err := d.checkLength(n); err != nil {
			return nil, 0, err
		}
		start := pos + 3
		if err := d.need(start, n); err != nil {
			return nil, 0, err
		}
		items := make([]any, n)
		for i := range items {
			items[i] = int64(d.data[start+i])
		}
		return items, start + int(n), nil
	case etfSmallTuple, etfLargeTuple:
		size := 1
		if tag == etfLargeTuple {
			size = 4
		}
		n, err := d.uintAt(pos+1, size)
		if err != nil {
			return nil, 0, err
		}
		if err := d.checkLength(n); err != nil {
			return nil, 0, err
		}
		items, next, err := d.decodeItems(pos+1+size, int(n), depth)
		if err != nil {
			return nil, 0, err
		}
		return Tuple(items), next, nil
	case etfMap:
		return d.decodeMap(pos, depth)
	case etfSmallBig, etfLargeBig:
		return d.decodeBig(pos, tag)
	case etfNewPid, etfPid:
		end, err := d.skipAtom(pos + 1)
		if err != nil {
			return nil, 0, err
		}
		if tag == etfNewPid {
			end += 12
		} else {
			end += 9
		}
		if err := d.need(pos, uint64(end-pos)); err != nil {
			return nil, 0, err
		}
		return Pid{raw: string(d.data[pos:end])}, end, nil
	case etfNewerReference, etfNewReference:
		n, err := d.uintAt(pos+1, 2)
		if err != nil {
			return nil, 0, err
		}
		end, err := d.skipAtom(pos + 3)
		if err != nil {
			return nil, 0, err
		}
		if tag == etfNewerReference {
			end += 4
		} else {
			end++
		}
		end += 4 * int(n)
		if err := d.need(pos, uint64(end-pos)); err != nil {
			return nil, 0, err
		}
		return Reference{raw: string(d.data[pos:end])}, end, nil
	}

	return nil, 0, codecErr("invalid_encoding", tag)
}

func (d *etfDecoder) decodeItems(pos, count, depth int) ([]any, int, error) {
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

func (d *etfDecoder) decodeList(pos, depth int) (any, int, error) {
	n, err := d.uintAt(pos+1, 4)
	if err != nil {
		return nil, 0, err
	}
	if err := d.checkLength(n); err != nil {
		return nil, 0, err
	}
	items, pos, err := d.decodeItems(pos+5, int(n), depth)
	if err != nil {
		return nil, 0, err
	}
	if err := d.need(pos, 1); err != nil {
		return nil, 0, err
	}
	if d.data[pos] == etfNil {
		return items, pos + 1, nil
	}
	tail, pos, err := d.decode(pos, depth+1)
	if err != nil {
		return nil, 0, err
	}
	return ImproperList{Items: items, Tail: tail}, pos, nil
}

func (d *etfDecoder) decodeMap(pos, depth int) (any, int, error) {
	n, err := d.uintAt(pos+1, 4)
	if err != nil {
		return nil, 0, err
	}
	if err := d.checkLength(n); err != nil {
		return nil, 0, err
	}
	pos += 5
	keys := make([]any, n)
	values := make([]any, n)
	for i := range keys {
		key, next, err := d.decode(pos, depth+1)
		if err != nil {
			return nil, 0, err
		}
		keys[i], pos = key, next
		if key == Atom(binDataKey) && pos < len(d.data) && d.data[pos] == etfBinary {
			raw, next, err := d.decodeBinary(pos)
			if err != nil {
				return nil, 0, err
			}
			values[i], pos = rawBinary(raw), next
			continue
		}
		value, next, err := d.decode(pos, depth+1)
		if err != nil {
			return nil, 0, err
		}
		values[i], pos = value, next
	}

	// A %Portals.Codec.Bin{} struct (keys in either order) is []byte.
	if n == 2 {
		var structName, data any
		for i, key := range keys {
			switch key {
			case Atom(binStructKey):
				structName = values[i]
			case Atom(binDataKey):
				data = values[i]
			}
		}
		if raw, ok := data.(rawBinary); ok && structName == Atom(binStructName) {
			return append([]byte{}, raw...), pos, nil
		}
	}

	// Keys become text, as under MessagePack.
	result := make(map[string]any, n)
	for i, key := range keys {
		text, err := keyText(key)
		if err != nil {
			return nil, 0, err
		}
		value := values[i]
		if raw, ok := value.(rawBinary); ok {
			if value, err = binaryText(raw); err != nil {
				return nil, 0, err
			}
		}
		result[text] = value
	}
	return result, pos, nil
}

// keyText is a decoded map key's string form, as the MessagePack encoders
// write keys (Elixir's to_string/1): binaries as text, atoms by name (nil
// as ""), integers in decimal.
func keyText(key any) (string, error) {
	switch k := key.(type) {
	case string:
		return k, nil
	case Atom:
		return string(k), nil
	case nil:
		return "", nil // Elixir's to_string(nil)
	case bool:
		return strconv.FormatBool(k), nil
	case int64:
		return strconv.FormatInt(k, 10), nil
	case uint64:
		return strconv.FormatUint(k, 10), nil
	case *big.Int:
		return k.String(), nil
	}
	return "", codecErr("invalid_encoding", fmt.Sprintf("unsupported map key %T", key))
}

// binaryText is a BINARY_EXT as a Go string, which must be UTF-8.
func binaryText(raw []byte) (string, error) {
	if !utf8.Valid(raw) {
		return "", codecErr("invalid_encoding", "binary is not UTF-8")
	}
	return string(raw), nil
}

// decodeBinary returns the bytes of the BINARY_EXT at pos (a view into the
// input, not a copy) and the position just after it.
func (d *etfDecoder) decodeBinary(pos int) ([]byte, int, error) {
	n, err := d.uintAt(pos+1, 4)
	if err != nil {
		return nil, 0, err
	}
	start := pos + 5
	if err := d.need(start, n); err != nil {
		return nil, 0, err
	}
	end := start + int(n)
	return d.data[start:end:end], end, nil
}

// decodeBig decodes SMALL_BIG_EXT / LARGE_BIG_EXT to int64, uint64 above
// math.MaxInt64, or *big.Int beyond 64 bits, like the MessagePack codec.
func (d *etfDecoder) decodeBig(pos int, tag uint64) (any, int, error) {
	size := 1
	if tag == etfLargeBig {
		size = 4
	}
	n, err := d.uintAt(pos+1, size)
	if err != nil {
		return nil, 0, err
	}
	start := pos + 1 + size
	if err := d.need(start, 1+n); err != nil {
		return nil, 0, err
	}
	negative := d.data[start] != 0
	digits := d.data[start+1 : start+1+int(n)]
	end := start + 1 + int(n)

	if len(digits) <= 8 {
		var magnitude uint64
		for i := len(digits) - 1; i >= 0; i-- {
			magnitude = magnitude<<8 | uint64(digits[i])
		}
		switch {
		case !negative && magnitude <= math.MaxInt64:
			return int64(magnitude), end, nil
		case !negative:
			return magnitude, end, nil
		case magnitude <= 1<<63:
			return -int64(magnitude-1) - 1, end, nil
		}
	}
	bigEndian := make([]byte, len(digits))
	for i, b := range digits {
		bigEndian[len(digits)-1-i] = b
	}
	value := new(big.Int).SetBytes(bigEndian)
	if negative {
		value.Neg(value)
	}
	if value.IsInt64() {
		return value.Int64(), end, nil
	}
	if value.IsUint64() {
		return value.Uint64(), end, nil
	}
	return value, end, nil
}

// decodeAtom returns the name of the atom at pos (Latin-1 atoms converted
// to UTF-8) and the position just after it.
func (d *etfDecoder) decodeAtom(pos int) (string, int, error) {
	tag, err := d.uintAt(pos, 1)
	if err != nil {
		return "", 0, err
	}
	size := 2
	switch tag {
	case etfSmallAtomUTF8, etfSmallAtom:
		size = 1
	case etfAtomUTF8, etfAtom:
	default:
		return "", 0, codecErr("invalid_encoding", tag)
	}
	n, err := d.uintAt(pos+1, size)
	if err != nil {
		return "", 0, err
	}
	start := pos + 1 + size
	if err := d.need(start, n); err != nil {
		return "", 0, err
	}
	end := start + int(n)
	text := d.data[start:end]
	if tag == etfSmallAtom || tag == etfAtom {
		runes := make([]rune, len(text))
		for i, b := range text {
			runes[i] = rune(b)
		}
		return string(runes), end, nil
	}
	if !utf8.Valid(text) {
		return "", 0, codecErr("invalid_encoding", "atom is not UTF-8")
	}
	return string(text), end, nil
}

// skipAtom returns the position just after the atom at pos (a PID's or
// reference's node name).
func (d *etfDecoder) skipAtom(pos int) (int, error) {
	_, end, err := d.decodeAtom(pos)
	return end, err
}
