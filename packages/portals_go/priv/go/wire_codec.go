package portals

import (
	"fmt"
	"os"
)

// The wire codec this worker speaks, chosen by the BEAM through the
// PORTALS_CODEC environment variable (protocol/v1.md section 5.4): "etf"
// (the default when unset) or "msgpack". It is read once, at startup, and
// every frame in both directions goes through it, HELLO included.
// Handlers never see it: values decode to the same Go types under either.

// Codec is one wire codec. Both codecs report failures as *CodecError with
// the same reasons.
type Codec struct {
	// Name is the PORTALS_CODEC value that selects the codec.
	Name string
	// Encode encodes one frame envelope (or any term), enforcing limits.
	Encode func(term any, limits Limits) ([]byte, error)
	// Decode decodes one term from data, returning it and any trailing
	// bytes.
	Decode func(data []byte, limits Limits) (term any, rest []byte, err error)
}

var (
	// ETF is the Erlang External Term Format codec (etf_codec.go).
	ETF = Codec{Name: "etf", Encode: EncodeETF, Decode: DecodeETF}
	// MessagePack is the MessagePack codec (codec.go).
	MessagePack = Codec{Name: "msgpack", Encode: EncodeMessagePack, Decode: DecodeMessagePack}
)

var selectedCodec, selectedCodecErr = codecNamed(os.Getenv("PORTALS_CODEC"))

// codecNamed resolves a PORTALS_CODEC value; empty means the default.
func codecNamed(name string) (Codec, error) {
	switch name {
	case "", ETF.Name:
		return ETF, nil
	case MessagePack.Name:
		return MessagePack, nil
	}
	return Codec{}, fmt.Errorf("portals: PORTALS_CODEC=%q is not a codec this SDK speaks (etf, msgpack)", name)
}

// SelectedCodec is the codec PORTALS_CODEC selected at startup, or an error
// when it names a codec this SDK does not speak. Worker.Run fails with that
// error before connecting.
func SelectedCodec() (Codec, error) { return selectedCodec, selectedCodecErr }

// Encode encodes one frame envelope (or any term) with the selected codec,
// enforcing limits.
func Encode(term any, limits Limits) ([]byte, error) {
	if selectedCodecErr != nil {
		return nil, selectedCodecErr
	}
	return selectedCodec.Encode(term, limits)
}

// Decode decodes one term from data with the selected codec, returning it
// and any trailing bytes.
func Decode(data []byte, limits Limits) (term any, rest []byte, err error) {
	if selectedCodecErr != nil {
		return nil, nil, selectedCodecErr
	}
	return selectedCodec.Decode(data, limits)
}
