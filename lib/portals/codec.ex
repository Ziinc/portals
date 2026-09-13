defmodule Portals.Codec do
  @moduledoc """
  Behaviour implemented by every wire codec (`Portals.Codec.MessagePack` in
  production, `Portals.Codec.ETFBench` for internal benchmarking only).

  A codec encodes/decodes a single frame envelope (a list whose head is the
  integer frame tag) to/from a binary. Codecs never see connection or
  transport state; they are pure functions over bytes and terms.
  """

  @type envelope :: list
  @type decode_error ::
          {:truncated, non_neg_integer}
          | {:trailing_bytes, non_neg_integer}
          | {:max_depth_exceeded, non_neg_integer}
          | {:max_length_exceeded, non_neg_integer}
          | {:max_size_exceeded, non_neg_integer}
          | {:unsafe_atom, binary}
          | {:invalid_extension, term}
          | {:invalid_encoding, term}

  @callback encode(envelope, Portals.Protocol.limits()) ::
              {:ok, binary} | {:error, decode_error}
  @callback decode(binary, Portals.Protocol.limits()) ::
              {:ok, envelope, rest :: binary} | {:error, decode_error}
end
