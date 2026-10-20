package portals

import (
	"bytes"
	"errors"
	"math"
	"math/big"
	"reflect"
	"testing"
)

func roundTrip(t *testing.T, term any) any {
	t.Helper()
	encoded, err := EncodeMessagePack(term, DefaultLimits)
	if err != nil {
		t.Fatalf("encode %#v: %v", term, err)
	}
	decoded, rest, err := DecodeMessagePack(encoded, DefaultLimits)
	if err != nil {
		t.Fatalf("decode %#v: %v", term, err)
	}
	if len(rest) != 0 {
		t.Fatalf("trailing bytes after %#v", term)
	}
	return decoded
}

func TestCoreTypesRoundTrip(t *testing.T) {
	big1, _ := new(big.Int).SetString("123456789012345678901234567890", 10)
	pid := Pid{raw: "\x83X\x00opaque"}
	cases := []any{
		nil, true, false,
		int64(0), int64(127), int64(128), int64(-1), int64(-32), int64(-33),
		int64(-129), int64(-32769), int64(math.MinInt32), int64(1 << 40),
		uint64(math.MaxUint64),
		0.5, "text", "", []byte{0, 1, 2, 255}, []byte{},
		[]any{int64(1), int64(2), int64(3)}, []any{},
		map[string]any{"nested": map[string]any{"ok": true}},
		Tuple{Atom("ok"), "value", int64(3)},
		Atom("some_atom"),
		big1,
		new(big.Int).Neg(big1),
		ImproperList{Items: []any{int64(1), int64(2)}, Tail: Atom("tail")},
		pid,
		Reference{raw: "ref-bytes"},
	}
	for _, term := range cases {
		if got := roundTrip(t, term); !reflect.DeepEqual(got, term) {
			t.Errorf("round trip of %#v gave %#v", term, got)
		}
	}
}

func TestSmallestIntegerEncodings(t *testing.T) {
	cases := map[int64][]byte{
		5:     {0x05},
		-1:    {0xFF},
		-33:   {0xD0, 0xDF},
		200:   {0xCC, 0xC8},
		70000: {0xCE, 0x00, 0x01, 0x11, 0x70},
	}
	for n, want := range cases {
		got, _ := EncodeMessagePack(n, DefaultLimits)
		if !bytes.Equal(got, want) {
			t.Errorf("EncodeMessagePack(%d) = % x, want % x", n, got, want)
		}
	}
}

func TestIntegersBelowTheLowerBoundUseTheBigintExtension(t *testing.T) {
	n := int64(intLowerBound - 1)
	encoded, _ := EncodeMessagePack(n, DefaultLimits)
	if encoded[0] != 0xC7 || encoded[2] != extBigint {
		t.Fatalf("expected an ext8 bigint, got % x", encoded)
	}
	if got := roundTrip(t, n); got != n {
		t.Fatalf("got %#v", got)
	}
}

func TestNativeAndReflectedGoTypesEncode(t *testing.T) {
	type label string
	got := roundTrip(t, map[string]any{
		"ints":   []int{1, 2},
		"names":  map[string]string{"a": "b"},
		"label":  label("x"),
		"small":  int8(-3),
		"float":  float32(1.5),
		"bytes":  [2]byte{9, 9},
		"absent": (*int)(nil),
	})
	want := map[string]any{
		"ints":   []any{int64(1), int64(2)},
		"names":  map[string]any{"a": "b"},
		"label":  "x",
		"small":  int64(-3),
		"float":  1.5,
		"bytes":  []byte{9, 9},
		"absent": nil,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v", got)
	}
}

func reasonOf(err error) string {
	var codecErr *CodecError
	if errors.As(err, &codecErr) {
		return codecErr.Reason
	}
	return ""
}

func TestMalformedInputIsRejectedWithTheDocumentedReason(t *testing.T) {
	// protocol/malformed/fixtures.exs
	cases := map[string]struct {
		data   []byte
		reason string
	}{
		"truncated_fixarray":           {[]byte{0x93, 0x01}, "truncated"},
		"truncated_str8_header":        {[]byte{0xD9}, "truncated"},
		"truncated_str8_body":          {append([]byte{0xD9, 10}, "short"...), "truncated"},
		"unknown_leading_byte":         {[]byte{0xC1}, "invalid_encoding"},
		"oversized_array_length":       {[]byte{0xDD, 0xFF, 0xFF, 0xFF, 0xFF}, "max_length_exceeded"},
		"invalid_extension_type":       {[]byte{0xD4, 99, 0}, "invalid_extension"},
		"bad_tuple_ext_trailing_bytes": {[]byte{0xC7, 2, 0, 0x90, 0x01}, "invalid_extension"},
		"empty_binary":                 {[]byte{}, "truncated"},
		"truncated_stream_data_chunk":  {append([]byte{0x93, 11, 7, 0xC4, 16}, "short"...), "truncated"},
		"truncated_credit_frame":       {[]byte{0x93, 11, 7}, "truncated"},
		"non_string_map_key":           {[]byte{0x81, 0x01, 0x02}, "invalid_encoding"},
	}
	for name, tc := range cases {
		_, _, err := DecodeMessagePack(tc.data, DefaultLimits)
		if got := reasonOf(err); got != tc.reason {
			t.Errorf("%s: got %q (%v), want %q", name, got, err, tc.reason)
		}
	}
}

func TestAtomsDecodeWithoutAnAtomTable(t *testing.T) {
	data := append([]byte{0xC7, 20, 1}, "not_a_real_atom_xyzq"...)
	term, _, err := DecodeMessagePack(data, DefaultLimits)
	if err != nil || term != Atom("not_a_real_atom_xyzq") {
		t.Fatalf("got %#v, %v", term, err)
	}
}

func TestLimitsAreEnforcedOnEncodeAndDecode(t *testing.T) {
	limits := DefaultLimits
	limits.MaxNestingDepth = 2
	deep := []any{[]any{[]any{[]any{}}}}
	if _, err := EncodeMessagePack(deep, limits); reasonOf(err) != "max_depth_exceeded" {
		t.Errorf("encode depth: %v", err)
	}
	encoded, _ := EncodeMessagePack(deep, DefaultLimits)
	if _, _, err := DecodeMessagePack(encoded, limits); reasonOf(err) != "max_depth_exceeded" {
		t.Errorf("decode depth: %v", err)
	}

	limits = DefaultLimits
	limits.MaxCollectionLength = 2
	if _, err := EncodeMessagePack([]any{1, 2, 3}, limits); reasonOf(err) != "max_length_exceeded" {
		t.Errorf("encode length: %v", err)
	}

	limits = DefaultLimits
	limits.MaxFrameSize = 8
	if _, err := EncodeMessagePack(make([]byte, 16), limits); reasonOf(err) != "max_size_exceeded" {
		t.Errorf("encode size: %v", err)
	}
	if _, _, err := DecodeMessagePack(make([]byte, 16), limits); reasonOf(err) != "max_size_exceeded" {
		t.Errorf("decode size: %v", err)
	}
}

func TestUnsupportedTypesAreCodecErrors(t *testing.T) {
	if _, err := EncodeMessagePack(struct{}{}, DefaultLimits); reasonOf(err) != "invalid_encoding" {
		t.Fatalf("got %v", err)
	}
	if _, err := EncodeMessagePack(map[int]any{1: 2}, DefaultLimits); reasonOf(err) != "invalid_encoding" {
		t.Fatalf("got %v", err)
	}
}
