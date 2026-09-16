defmodule Portals.Codec.ETFBench do
  @moduledoc """
  Benchmark-only alternate codec (Phase 8/PRD section "Protocol
  compatibility"). Erlang's own External Term Format is *not* a supported
  production wire format for Portals — no non-BEAM SDK can produce or
  consume it without reimplementing BEAM-specific term tagging — but it is
  a useful reference point when isolating "how much of MessagePack's cost
  is inherent to any binary term codec versus specific to MessagePack" in
  `bench/codec_micro_bench.exs`.

  Decoding uses `:erlang.binary_to_term/2` with the `:safe` option, so it
  never creates new atoms and never accepts function values, matching the
  atom-safety rule the rest of the codebase applies (see
  `Portals.TermExtensions`).
  """

  @behaviour Portals.Codec

  @impl true
  def encode(envelope, limits) when is_list(envelope) do
    body = :erlang.term_to_binary(envelope)
    size = byte_size(body)

    if size > limits.max_frame_size do
      {:error, {:max_size_exceeded, size}}
    else
      {:ok, body}
    end
  end

  @impl true
  def decode(binary, limits) when is_binary(binary) do
    size = byte_size(binary)

    if size > limits.max_frame_size do
      {:error, {:max_size_exceeded, size}}
    else
      case :erlang.binary_to_term(binary, [:safe]) do
        term when is_list(term) -> {:ok, term, <<>>}
        term -> {:ok, [term], <<>>}
      end
    end
  rescue
    ArgumentError -> {:error, {:invalid_encoding, :etf}}
  end
end
