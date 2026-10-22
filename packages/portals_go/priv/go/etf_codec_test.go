package portals

import (
	"bytes"
	"encoding/hex"
	"math"
	"math/big"
	"reflect"
	"strings"
	"testing"
)

// Mirrors packages/portals_python/priv/python/tests/test_etf_codec.py.

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func etfRoundTrip(t *testing.T, term any) any {
	t.Helper()
	encoded, err := EncodeETF(term, DefaultLimits)
	if err != nil {
		t.Fatalf("encode %#v: %v", term, err)
	}
	decoded, rest, err := DecodeETF(encoded, DefaultLimits)
	if err != nil {
		t.Fatalf("decode %#v: %v", term, err)
	}
	if len(rest) != 0 {
		t.Fatalf("trailing bytes after %#v", term)
	}
	return decoded
}

// :erlang.term_to_binary/1 of
//
//	[3, 7, "héllo", %{"k" => [1, -2, 300, 2_147_483_648, -(2**70)]},
//	 {:ok, nil, true, false}, 1.5, [], ~c"ab", [1 | 2],
//	 %Portals.Codec.Bin{data: <<0, 255>>}]
const beamHex = "836c0000000a610361076d0000000668c3a96c6c6f74000000016d000000016b6c00000005610162fffffffe" +
	"620000012c6e0400000000806e09010000000000000000406a68046400026f6b6400036e696c640004747275" +
	"6564000566616c7365463ff80000000000006a6b000261626c0000000161016102740000000264000a5f5f73" +
	"74727563745f5f640018456c697869722e506f7274616c732e436f6465632e42696e640004646174616d0000" +
	"000200ff6a"

func TestETFDecodesWhatTheBeamEncodes(t *testing.T) {
	minus2to70 := new(big.Int).Neg(new(big.Int).Lsh(big.NewInt(1), 70))
	want := []any{
		int64(3),
		int64(7),
		"héllo",
		map[string]any{"k": []any{int64(1), int64(-2), int64(300), int64(2_147_483_648), minus2to70}},
		Tuple{Atom("ok"), nil, true, false},
		1.5,
		[]any{},
		[]any{int64(97), int64(98)},
		ImproperList{Items: []any{int64(1)}, Tail: int64(2)},
		[]byte{0, 255},
	}
	term, rest, err := DecodeETF(mustHex(t, beamHex), DefaultLimits)
	if err != nil || len(rest) != 0 {
		t.Fatalf("got %v, rest % x", err, rest)
	}
	if !reflect.DeepEqual(term, want) {
		t.Fatalf("got %#v", term)
	}
}

func TestETFRoundTripsEveryValueType(t *testing.T) {
	big1, _ := new(big.Int).SetString("123456789012345678901234567890", 10)
	huge := new(big.Int).Neg(new(big.Int).Lsh(big.NewInt(1), 2100))
	envelope := []any{
		int64(4),
		int64(1),
		map[string]any{
			"none":  nil,
			"bools": []any{true, false},
			"ints": []any{
				int64(0), int64(255), int64(256), int64(-1), int64(math.MaxInt32), int64(math.MinInt32),
				int64(1 << 31), int64(-(1 << 31) - 1), int64(math.MaxInt64), int64(math.MinInt64),
				uint64(math.MaxUint64), big1, new(big.Int).Neg(big1), huge,
			},
			"float":     -0.25,
			"text":      "naïve ✓",
			"empty":     "",
			"bytes":     []byte{0, 1, 0xFE},
			"no_bytes":  []byte{},
			"atom":      Atom("ok"),
			"tuple":     Tuple{int64(1), "two", Tuple{int64(3)}},
			"improper":  ImproperList{Items: []any{int64(1), int64(2)}, Tail: "tail"},
			"nested":    map[string]any{"a": []any{map[string]any{"b": []any{}}}},
			"no_map":    map[string]any{},
			"long":      Tuple(make([]any, 300)),
			"long_atom": Atom(strings.Repeat("a", 300)),
		},
	}
	if got := etfRoundTrip(t, envelope); !reflect.DeepEqual(got, envelope) {
		t.Fatalf("got %#v", got)
	}
}

func TestETFIntegerEncodings(t *testing.T) {
	cases := map[int64]string{
		5:              "836105",
		255:            "8361ff",
		256:            "836200000100",
		-1:             "8362ffffffff",
		1 << 31:        "836e040000000080",
		-(1 << 31) - 1: "836e040101000080",
	}
	for n, want := range cases {
		got, _ := EncodeETF(n, DefaultLimits)
		if hex.EncodeToString(got) != want {
			t.Errorf("EncodeETF(%d) = %x, want %s", n, got, want)
		}
	}
}

func TestETFPidsAndReferencesAreOpaqueAndWrittenBackVerbatim(t *testing.T) {
	// self() and make_ref() from a BEAM, as NEW_PID_EXT / NEWER_REFERENCE_EXT.
	pid := mustHex(t, "5864000d6e6f6e6f6465406e6f686f73740000005e0000000000000000")
	ref := mustHex(t, "5a000364000d6e6f6e6f6465406e6f686f73740000000000008033634c0004263763cf")
	data := append([]byte{131, 108, 0, 0, 0, 2}, pid...)
	data = append(append(data, ref...), 106)

	term, _, err := DecodeETF(data, DefaultLimits)
	want := []any{Pid{raw: string(pid)}, Reference{raw: string(ref)}}
	if err != nil || !reflect.DeepEqual(term, want) {
		t.Fatalf("got %#v, %v", term, err)
	}
	encoded, err := EncodeETF(term, DefaultLimits)
	if err != nil || !bytes.Equal(encoded, data) {
		t.Fatalf("got % x, %v", encoded, err)
	}

	// A PID that did not come from an ETF decode is refused, not sent.
	if _, err := EncodeETF(Pid{}, DefaultLimits); reasonOf(err) != "invalid_encoding" {
		t.Fatalf("got %v", err)
	}
}

func TestETFBinStructIsBytesWithKeysInEitherOrder(t *testing.T) {
	// %Portals.Codec.Bin{data: <<1, 2>>} with data written first.
	data := []byte{131, 116, 0, 0, 0, 2, 119, 4}
	data = append(data, "data"...)
	data = append(data, 109, 0, 0, 0, 2, 1, 2, 119, 10)
	data = append(data, "__struct__"...)
	data = append(data, 119, 24)
	data = append(data, "Elixir.Portals.Codec.Bin"...)
	term, _, err := DecodeETF(data, DefaultLimits)
	if err != nil || !reflect.DeepEqual(term, []byte{1, 2}) {
		t.Fatalf("got %#v, %v", term, err)
	}
}

func TestETFADataKeyOutsideABinStructStaysText(t *testing.T) {
	// %{data: "x", other: 1}
	data := []byte{131, 116, 0, 0, 0, 2, 119, 4}
	data = append(data, "data"...)
	data = append(data, 109, 0, 0, 0, 1, 'x', 119, 5)
	data = append(data, "other"...)
	data = append(data, 97, 1)
	term, _, err := DecodeETF(data, DefaultLimits)
	if err != nil || !reflect.DeepEqual(term, map[string]any{"data": "x", "other": int64(1)}) {
		t.Fatalf("got %#v, %v", term, err)
	}

	got := etfRoundTrip(t, map[string]any{"data": "x", "other": int64(1)})
	if !reflect.DeepEqual(got, map[string]any{"data": "x", "other": int64(1)}) {
		t.Fatalf("got %#v", got)
	}
}

func TestETFMapKeysBecomeTextAsUnderMessagePack(t *testing.T) {
	// %{a: 1, 2 => 3, "s" => 4, nil => 5} from a BEAM.
	beam := mustHex(t, "837400000004610261036400016161016400036e696c61056d00000001736104")
	term, _, err := DecodeETF(beam, DefaultLimits)
	want := map[string]any{"2": int64(3), "a": int64(1), "s": int64(4), "": int64(5)}
	if err != nil || !reflect.DeepEqual(term, want) {
		t.Fatalf("got %#v, %v", term, err)
	}

	// Keys are always written as binaries.
	encoded, _ := EncodeETF(map[string]any{"k": int64(1)}, DefaultLimits)
	if hex.EncodeToString(encoded) != "8374000000016d000000016b6101" {
		t.Fatalf("got %x", encoded)
	}

	// A key with no string form is rejected: %{{1} => 1}.
	tupleKey := []byte{131, 116, 0, 0, 0, 1, 104, 1, 97, 1, 97, 1}
	if _, _, err := DecodeETF(tupleKey, DefaultLimits); reasonOf(err) != "invalid_encoding" {
		t.Fatalf("got %v", err)
	}
}

func TestETFLatin1AtomsDecodeToText(t *testing.T) {
	// SMALL_ATOM_EXT "é" in Latin-1, and ATOM_EXT "ok".
	data := []byte{131, 108, 0, 0, 0, 2, 115, 1, 0xE9, 100, 0, 2, 'o', 'k', 106}
	term, _, err := DecodeETF(data, DefaultLimits)
	if err != nil || !reflect.DeepEqual(term, []any{Atom("é"), Atom("ok")}) {
		t.Fatalf("got %#v, %v", term, err)
	}
}

func TestETFMalformedInputIsRejectedWithTheDocumentedReason(t *testing.T) {
	beam := mustHex(t, beamHex)
	nested := []byte{131}
	for i := 0; i < 40; i++ {
		nested = append(nested, 108, 0, 0, 0, 1)
	}
	nested = append(nested, 97, 1)
	nested = append(nested, bytes.Repeat([]byte{106}, 40)...)

	// protocol/malformed/etf_fixtures.exs, classified as
	// Portals.Conformance.SDKSuite.expected_reasons(:etf).
	cases := map[string]struct {
		data   []byte
		reason string
	}{
		"etf_empty_binary":          {[]byte{}, "truncated"},
		"etf_missing_version_byte":  {[]byte{108, 0, 0, 0, 1, 97, 1, 106}, "invalid_encoding"},
		"etf_truncated_list":        {[]byte{131, 108, 0, 0, 0, 3, 97, 1}, "truncated"},
		"etf_truncated_binary":      {append([]byte{131, 109, 0, 0, 0, 10}, "short"...), "truncated"},
		"etf_unknown_tag":           {[]byte{131, 200}, "invalid_encoding"},
		"etf_oversized_list_length": {[]byte{131, 108, 0xFF, 0xFF, 0xFF, 0xFF}, "max_length_exceeded"},
		"etf_binary_not_utf8":       {[]byte{131, 109, 0, 0, 0, 2, 0xC3, 0x28}, "invalid_encoding"},
		"etf_bit_binary":            {[]byte{131, 77, 0, 0, 0, 1, 3, 0xE0}, "invalid_encoding"},
		"etf_nesting_too_deep":      {nested, "max_depth_exceeded"},
		"etf_truncated_stream_data_chunk": {
			append([]byte{131, 108, 0, 0, 0, 3, 97, 11, 97, 7, 109, 0, 0, 0, 16}, "short"...), "truncated",
		},
		"truncated_golden_term":    {beam[:len(beam)-3], "truncated"},
		"truncated_pid":            {mustHex(t, "835864000d6e6f6e6f6465406e6f686f7374000000"), "truncated"},
		"compressed_term":          {[]byte{131, 80, 0, 0, 0, 1, 0}, "invalid_encoding"},
		"old_float":                {append([]byte{131, 99}, make([]byte, 31)...), "invalid_encoding"},
		"bin_struct_not_utf8_data": {[]byte{131, 116, 0, 0, 0, 1, 119, 4, 'd', 'a', 't', 'a', 109, 0, 0, 0, 1, 0xFF}, "invalid_encoding"},
	}
	for name, tc := range cases {
		_, _, err := DecodeETF(tc.data, DefaultLimits)
		if got := reasonOf(err); got != tc.reason {
			t.Errorf("%s: got %q (%v), want %q", name, got, err, tc.reason)
		}
	}

	// Accepted, with what follows the term left for the frame reader.
	term, rest, err := DecodeETF([]byte{131, 119, 20, 'n', 'o', 't', '_', 'a', '_', 'r', 'e', 'a', 'l', '_',
		'a', 't', 'o', 'm', '_', 'x', 'y', 'z', 'q', 0}, DefaultLimits)
	if err != nil || term != Atom("not_a_real_atom_xyzq") || !bytes.Equal(rest, []byte{0}) {
		t.Fatalf("got %#v, % x, %v", term, rest, err)
	}
}

func TestETFLimitsAreEnforcedOnEncodeAndDecode(t *testing.T) {
	limits := DefaultLimits
	limits.MaxNestingDepth = 2
	deep := []any{[]any{[]any{[]any{int64(1)}}}}
	if _, err := EncodeETF(deep, limits); reasonOf(err) != "max_depth_exceeded" {
		t.Errorf("encode depth: %v", err)
	}
	encoded, _ := EncodeETF(deep, DefaultLimits)
	if _, _, err := DecodeETF(encoded, limits); reasonOf(err) != "max_depth_exceeded" {
		t.Errorf("decode depth: %v", err)
	}

	limits = DefaultLimits
	limits.MaxCollectionLength = 3
	for _, term := range []any{
		[]any{1, 2, 3, 4},
		Tuple{1, 2, 3, 4},
		map[string]any{"a": 1, "b": 2, "c": 3, "d": 4},
		[]int{1, 2, 3, 4},
	} {
		if _, err := EncodeETF(term, limits); reasonOf(err) != "max_length_exceeded" {
			t.Errorf("encode length of %#v: %v", term, err)
		}
		encoded, _ := EncodeETF(term, DefaultLimits)
		if _, _, err := DecodeETF(encoded, limits); reasonOf(err) != "max_length_exceeded" {
			t.Errorf("decode length of %#v: %v", term, err)
		}
	}

	limits = DefaultLimits
	limits.MaxFrameSize = 1024
	if _, err := EncodeETF(strings.Repeat("x", 2000), limits); reasonOf(err) != "max_size_exceeded" {
		t.Errorf("encode size: %v", err)
	}
	if _, _, err := DecodeETF(make([]byte, 2000), limits); reasonOf(err) != "max_size_exceeded" {
		t.Errorf("decode size: %v", err)
	}
}

func TestETFNativeAndReflectedGoTypesEncode(t *testing.T) {
	type label string
	got := etfRoundTrip(t, map[string]any{
		"ints":   []int{1, 2},
		"names":  map[string]string{"a": "b"},
		"label":  label("x"),
		"small":  int8(-3),
		"float":  float32(1.5),
		"bytes":  [2]byte{9, 9},
		"absent": (*int)(nil),
		"none":   []string(nil),
		"error":  &Error{Kind: "remote", Message: "boom"},
	})
	want := map[string]any{
		"ints":   []any{int64(1), int64(2)},
		"names":  map[string]any{"a": "b"},
		"label":  "x",
		"small":  int64(-3),
		"float":  1.5,
		"bytes":  []byte{9, 9},
		"absent": nil,
		"none":   []any{},
		"error":  etfRoundTrip(t, (&Error{Kind: "remote", Message: "boom"}).toMap()),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v", got)
	}
	if _, err := EncodeETF(struct{}{}, DefaultLimits); reasonOf(err) != "invalid_encoding" {
		t.Fatalf("got %v", err)
	}
	if _, err := EncodeETF(map[int]any{1: 2}, DefaultLimits); reasonOf(err) != "invalid_encoding" {
		t.Fatalf("got %v", err)
	}
}

func TestCodecSelection(t *testing.T) {
	for name, want := range map[string]string{"": "etf", "etf": "etf", "msgpack": "msgpack"} {
		codec, err := codecNamed(name)
		if err != nil || codec.Name != want {
			t.Errorf("codecNamed(%q) = %q, %v", name, codec.Name, err)
		}
	}
	if _, err := codecNamed("json"); err == nil || !strings.Contains(err.Error(), `PORTALS_CODEC="json"`) {
		t.Errorf("got %v", err)
	}
	// Every codec decodes to the same Go values.
	term := []any{int64(1), "x", []byte{1}, Tuple{Atom("ok")}, map[string]any{"k": uint64(math.MaxUint64)}}
	for _, codec := range []Codec{ETF, MessagePack} {
		encoded, err := codec.Encode(term, DefaultLimits)
		if err != nil {
			t.Fatal(err)
		}
		if got, _, err := codec.Decode(encoded, DefaultLimits); err != nil || !reflect.DeepEqual(got, term) {
			t.Errorf("%s: got %#v, %v", codec.Name, got, err)
		}
	}
}
