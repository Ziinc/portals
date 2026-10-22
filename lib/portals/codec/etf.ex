defmodule Portals.Codec.ETF do
  @moduledoc """
  The default wire codec: each frame envelope is the Erlang External Term
  Format (`:erlang.term_to_binary/1`).

  Encoding enforces every limit in `Portals.Protocol.default_limits/0` and rejects
  values no SDK can represent (functions, ports, bitstrings that are not
  whole bytes) before anything is sent. Decoding uses
  `:erlang.binary_to_term/2` with `:safe`, so a worker can never create
  atoms or functions on the BEAM; the frame size bounds everything else.

  `%Portals.Codec.Bin{}` travels as the struct itself, which every SDK maps
  to and from its byte-buffer type, so values have the same types as under
  `Portals.Codec.MessagePack`. See `protocol/v1.md` section 5.4.
  """

  @behaviour Portals.Codec

  @impl true
  def encode(envelope, limits) when is_list(envelope) do
    with :ok <- check(envelope, 0, limits) do
      body = :erlang.term_to_binary(envelope)
      size = byte_size(body)

      if size > limits.max_frame_size,
        do: {:error, {:max_size_exceeded, size}},
        else: {:ok, body}
    end
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

  # The checks Portals.Codec.MessagePack makes while encoding, as one walk.
  defp check(_term, depth, %{max_nesting_depth: max}) when depth > max,
    do: {:error, {:max_depth_exceeded, depth}}

  defp check(term, _depth, _limits)
       when is_atom(term) or is_number(term) or is_binary(term) or is_pid(term) or
              is_reference(term),
       do: :ok

  defp check(list, depth, limits) when is_list(list) do
    case collection_length(list, 0) do
      {:proper, n} when n > limits.max_collection_length -> {:error, {:max_length_exceeded, n}}
      _ -> check_all(list, depth + 1, limits)
    end
  end

  defp check(tuple, depth, limits) when is_tuple(tuple) do
    n = tuple_size(tuple)

    if n > limits.max_collection_length,
      do: {:error, {:max_length_exceeded, n}},
      else: check_all(Tuple.to_list(tuple), depth + 1, limits)
  end

  defp check(%Portals.Codec.Bin{data: data}, _depth, _limits) when is_binary(data), do: :ok

  defp check(map, depth, limits) when is_map(map) do
    n = map_size(map)

    if n > limits.max_collection_length do
      {:error, {:max_length_exceeded, n}}
    else
      Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
        with :ok <- check(key, depth + 1, limits),
             :ok <- check(value, depth + 1, limits) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp check(other, _depth, _limits), do: {:error, {:invalid_encoding, {:unsupported, other}}}

  defp check_all([], _depth, _limits), do: :ok

  defp check_all([head | tail], depth, limits) do
    with :ok <- check(head, depth, limits), do: check_all(tail, depth, limits)
  end

  # An improper tail is checked like any other element.
  defp check_all(tail, depth, limits), do: check(tail, depth, limits)

  defp collection_length([], n), do: {:proper, n}
  defp collection_length([_ | tail], n), do: collection_length(tail, n + 1)
  defp collection_length(_tail, n), do: {:improper, n}
end
