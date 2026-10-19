defmodule Portals.Codec.ETFBench do
  @moduledoc """
  Benchmark-only wire codec: frames are the Erlang External Term Format
  (`:erlang.term_to_binary/1`) instead of MessagePack.

  It exists so the benchmark suite (`bench/` in the repository) can compare
  the full Portals request path under both encodings. It is not a supported
  codec: only the Python SDK implements it (opted into with
  `PORTALS_CODEC=etf`), it enforces `max_frame_size` but not the nesting
  and collection-length limits, and decoding uses `:safe`, so atoms the
  BEAM has not seen are rejected rather than created.

  Select it with the internal `codec:` worker option:

      Portals.Python.worker_opts(
        script: "worker.py",
        codec: Portals.Codec.ETFBench,
        env: [{"PORTALS_CODEC", "etf"}]
      )

  `%Portals.Codec.Bin{}` travels as the struct itself (a map), which the
  Python SDK maps to and from `bytes`, so values cross the boundary with
  the same types as under MessagePack.
  """

  @behaviour Portals.Codec

  @impl true
  def encode(envelope, limits) when is_list(envelope) do
    body = :erlang.term_to_binary(envelope)
    size = byte_size(body)

    if size > limits.max_frame_size,
      do: {:error, {:max_size_exceeded, size}},
      else: {:ok, body}
  end

  @impl true
  def decode(binary, limits) when is_binary(binary) do
    size = byte_size(binary)

    if size > limits.max_frame_size do
      {:error, {:max_size_exceeded, size}}
    else
      {term, used} = :erlang.binary_to_term(binary, [:safe, :used])
      <<_::binary-size(used), rest::binary>> = binary
      {:ok, if(is_list(term), do: term, else: [term]), rest}
    end
  rescue
    ArgumentError -> {:error, {:invalid_encoding, :etf}}
  end
end
