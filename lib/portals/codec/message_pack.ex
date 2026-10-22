defmodule Portals.Codec.MessagePack do
  @moduledoc """
  The mandatory, portable 1.0 wire codec: MessagePack core types plus the
  Portals Erlang-value extensions from `Portals.TermExtensions`.

  Encodes/decodes one frame envelope (`[tag | fields]`) at a time. Enforces
  `max_frame_size`, `max_nesting_depth`, and `max_collection_length` from
  the caller-supplied limits before allocating nested structures.
  """

  @behaviour Portals.Codec

  alias Portals.TermExtensions

  @impl true
  def encode(envelope, limits) when is_list(envelope) do
    start = System.monotonic_time()

    result =
      try do
        body = encode_term(envelope, 0, limits)
        size = byte_size(body)

        if size > limits.max_frame_size do
          {:error, {:max_size_exceeded, size}}
        else
          {:ok, body}
        end
      catch
        {:portals_codec_error, reason} -> {:error, reason}
      end

    size = with {:ok, body} <- result, do: byte_size(body)
    size = if is_integer(size), do: size, else: 0

    Portals.Telemetry.codec_encode_stop(System.monotonic_time() - start, size, %{
      codec: __MODULE__
    })

    result
  end

  @impl true
  def decode(binary, limits) when is_binary(binary) do
    start = System.monotonic_time()
    size = byte_size(binary)

    result =
      if size > limits.max_frame_size do
        {:error, {:max_size_exceeded, size}}
      else
        try do
          case decode_term(binary, 0, limits) do
            {:ok, term, rest} when is_list(term) -> {:ok, term, rest}
            {:ok, term, rest} -> {:ok, [term], rest}
            {:error, _} = err -> err
          end
        catch
          {:portals_codec_error, reason} -> {:error, reason}
        end
      end

    Portals.Telemetry.codec_decode_stop(System.monotonic_time() - start, size, %{
      codec: __MODULE__
    })

    result
  end

  # -- Encoding ---------------------------------------------------------

  defp encode_term(_term, depth, limits) when depth > limits.max_nesting_depth do
    throw({:portals_codec_error, {:max_depth_exceeded, depth}})
  end

  defp encode_term(nil, _depth, _limits), do: <<0xC0>>
  defp encode_term(false, _depth, _limits), do: <<0xC2>>
  defp encode_term(true, _depth, _limits), do: <<0xC3>>

  defp encode_term(int, _depth, _limits)
       when is_integer(int) and int >= -1_099_511_627_776 and
              int < 18_446_744_073_709_551_616 do
    encode_int(int)
  end

  defp encode_term(int, depth, limits) when is_integer(int) do
    encode_ext(:bigint, TermExtensions.encode_bigint(int), depth, limits)
  end

  defp encode_term(float, _depth, _limits) when is_float(float), do: <<0xCB, float::float-64>>

  defp encode_term(%Portals.Codec.Bin{data: bin}, _depth, _limits) when is_binary(bin) do
    len = byte_size(bin)

    header =
      cond do
        len < 256 -> <<0xC4, len::8>>
        len < 65536 -> <<0xC5, len::16>>
        true -> <<0xC6, len::32>>
      end

    header <> bin
  end

  defp encode_term(atom, depth, limits) when is_atom(atom) do
    encode_ext(:atom, TermExtensions.encode_atom(atom), depth, limits)
  end

  defp encode_term(pid, depth, limits) when is_pid(pid) do
    encode_ext(:pid, TermExtensions.encode_pid(pid), depth, limits)
  end

  defp encode_term(ref, depth, limits) when is_reference(ref) do
    encode_ext(:reference, TermExtensions.encode_reference(ref), depth, limits)
  end

  defp encode_term(str, _depth, _limits) when is_binary(str) do
    encode_string(str)
  end

  defp encode_term(tuple, depth, limits) when is_tuple(tuple) do
    list = Tuple.to_list(tuple)
    check_length(length(list), limits, depth)
    payload = encode_array(list, depth + 1, limits)
    encode_ext(:tuple, payload, depth, limits)
  end

  defp encode_term(map, depth, limits) when is_map(map) do
    check_length(map_size(map), limits, depth)
    encode_map(map, depth, limits)
  end

  defp encode_term(list, depth, limits) when is_list(list) do
    case proper_list?(list) do
      true ->
        check_length(length(list), limits, depth)
        encode_array(list, depth + 1, limits)

      false ->
        {proper_part, tail} = split_improper(list)
        payload = encode_array([proper_part, tail], depth + 1, limits)
        encode_ext(:improper_list, payload, depth, limits)
    end
  end

  defp encode_string(str) do
    len = byte_size(str)

    header =
      cond do
        len < 32 -> <<0b101::3, len::5>>
        len < 256 -> <<0xD9, len::8>>
        len < 65536 -> <<0xDA, len::16>>
        true -> <<0xDB, len::32>>
      end

    header <> str
  end

  defp encode_array(list, depth, limits) do
    len = length(list)
    header = array_header(len)
    body = Enum.map_join(list, "", &encode_term(&1, depth, limits))
    header <> body
  end

  defp array_header(len) when len < 16, do: <<0b1001::4, len::4>>
  defp array_header(len) when len < 65536, do: <<0xDC, len::16>>
  defp array_header(len), do: <<0xDD, len::32>>

  defp encode_map(map, depth, limits) do
    len = map_size(map)
    header = map_header(len)

    body =
      Enum.map_join(map, "", fn {k, v} ->
        key_bin = to_string(k)
        encode_string(key_bin) <> encode_term(v, depth + 1, limits)
      end)

    header <> body
  end

  defp map_header(len) when len < 16, do: <<0b1000::4, len::4>>
  defp map_header(len) when len < 65536, do: <<0xDE, len::16>>
  defp map_header(len), do: <<0xDF, len::32>>

  defp encode_int(int) when int >= 0 and int < 128, do: <<0::1, int::7>>
  defp encode_int(int) when int < 0 and int >= -32, do: <<0b111::3, int::5>>
  defp encode_int(int) when int >= 0 and int < 256, do: <<0xCC, int::8>>
  defp encode_int(int) when int >= 0 and int < 65536, do: <<0xCD, int::16>>
  defp encode_int(int) when int >= 0 and int < 4_294_967_296, do: <<0xCE, int::32>>
  defp encode_int(int) when int >= 0, do: <<0xCF, int::64>>
  defp encode_int(int) when int >= -128, do: <<0xD0, int::signed-8>>
  defp encode_int(int) when int >= -32768, do: <<0xD1, int::signed-16>>
  defp encode_int(int) when int >= -2_147_483_648, do: <<0xD2, int::signed-32>>
  defp encode_int(int), do: <<0xD3, int::signed-64>>

  defp encode_ext(type, payload, _depth, _limits) do
    type_code = TermExtensions.ext_type_code(type)
    len = byte_size(payload)

    header =
      case len do
        1 -> <<0xD4, type_code::signed-8>>
        2 -> <<0xD5, type_code::signed-8>>
        4 -> <<0xD6, type_code::signed-8>>
        8 -> <<0xD7, type_code::signed-8>>
        16 -> <<0xD8, type_code::signed-8>>
        _ when len < 256 -> <<0xC7, len::8, type_code::signed-8>>
        _ when len < 65536 -> <<0xC8, len::16, type_code::signed-8>>
        _ -> <<0xC9, len::32, type_code::signed-8>>
      end

    header <> payload
  end

  defp check_length(len, limits, _depth) when len > limits.max_collection_length do
    throw({:portals_codec_error, {:max_length_exceeded, len}})
  end

  defp check_length(_len, _limits, _depth), do: :ok

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_), do: false

  defp split_improper(list, acc \\ [])
  defp split_improper([h | t], acc) when is_list(t), do: split_improper(t, [h | acc])
  defp split_improper([h | tail], acc), do: {Enum.reverse([h | acc]), tail}

  # -- Decoding -----------------------------------------------------------

  defp decode_term(_bin, depth, limits) when depth > limits.max_nesting_depth do
    throw({:portals_codec_error, {:max_depth_exceeded, depth}})
  end

  defp decode_term(<<0xC0, rest::binary>>, _depth, _limits), do: {:ok, nil, rest}
  defp decode_term(<<0xC2, rest::binary>>, _depth, _limits), do: {:ok, false, rest}
  defp decode_term(<<0xC3, rest::binary>>, _depth, _limits), do: {:ok, true, rest}

  defp decode_term(<<0::1, int::7, rest::binary>>, _depth, _limits), do: {:ok, int, rest}

  defp decode_term(<<0b111::3, int::5, rest::binary>>, _depth, _limits),
    do: {:ok, int - 32, rest}

  defp decode_term(<<0xCC, int::8, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xCD, int::16, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xCE, int::32, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xCF, int::64, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xD0, int::signed-8, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xD1, int::signed-16, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xD2, int::signed-32, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xD3, int::signed-64, rest::binary>>, _depth, _limits), do: {:ok, int, rest}
  defp decode_term(<<0xCB, f::float-64, rest::binary>>, _depth, _limits), do: {:ok, f, rest}

  defp decode_term(<<0xC4, len::8, bin::binary-size(len), rest::binary>>, _depth, _limits),
    do: {:ok, %Portals.Codec.Bin{data: bin}, rest}

  defp decode_term(<<0xC5, len::16, bin::binary-size(len), rest::binary>>, _depth, _limits),
    do: {:ok, %Portals.Codec.Bin{data: bin}, rest}

  defp decode_term(<<0xC6, len::32, bin::binary-size(len), rest::binary>>, _depth, _limits),
    do: {:ok, %Portals.Codec.Bin{data: bin}, rest}

  defp decode_term(<<0b101::3, len::5, str::binary-size(len), rest::binary>>, _depth, _limits),
    do: {:ok, str, rest}

  defp decode_term(<<0xD9, len::8, str::binary-size(len), rest::binary>>, _depth, _limits),
    do: {:ok, str, rest}

  defp decode_term(<<0xDA, len::16, str::binary-size(len), rest::binary>>, _depth, _limits),
    do: {:ok, str, rest}

  defp decode_term(<<0xDB, len::32, str::binary-size(len), rest::binary>>, _depth, _limits),
    do: {:ok, str, rest}

  defp decode_term(<<0b1001::4, len::4, rest::binary>>, depth, limits),
    do: decode_array(len, rest, depth, limits)

  defp decode_term(<<0xDC, len::16, rest::binary>>, depth, limits),
    do: decode_array(len, rest, depth, limits)

  defp decode_term(<<0xDD, len::32, rest::binary>>, depth, limits),
    do: decode_array(len, rest, depth, limits)

  defp decode_term(<<0b1000::4, len::4, rest::binary>>, depth, limits),
    do: decode_map(len, rest, depth, limits)

  defp decode_term(<<0xDE, len::16, rest::binary>>, depth, limits),
    do: decode_map(len, rest, depth, limits)

  defp decode_term(<<0xDF, len::32, rest::binary>>, depth, limits),
    do: decode_map(len, rest, depth, limits)

  defp decode_term(
         <<0xD4, type::signed-8, payload::binary-size(1), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(
         <<0xD5, type::signed-8, payload::binary-size(2), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(
         <<0xD6, type::signed-8, payload::binary-size(4), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(
         <<0xD7, type::signed-8, payload::binary-size(8), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(
         <<0xD8, type::signed-8, payload::binary-size(16), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(
         <<0xC7, len::8, type::signed-8, payload::binary-size(len), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(
         <<0xC8, len::16, type::signed-8, payload::binary-size(len), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(
         <<0xC9, len::32, type::signed-8, payload::binary-size(len), rest::binary>>,
         depth,
         limits
       ),
       do: decode_ext(type, payload, depth, limits, rest)

  defp decode_term(<<>>, _depth, _limits), do: throw({:portals_codec_error, {:truncated, 0}})

  @known_headers [
    0xC4,
    0xC5,
    0xC6,
    0xC7,
    0xC8,
    0xC9,
    0xD4,
    0xD5,
    0xD6,
    0xD7,
    0xD8,
    0xD9,
    0xDA,
    0xDB,
    0xDC,
    0xDD,
    0xDE,
    0xDF
  ]

  defp decode_term(<<byte, _::binary>> = other, _depth, _limits)
       when byte in @known_headers or (byte >= 0b10010000 and byte <= 0b10011111) or
              (byte >= 0b10000000 and byte <= 0b10001111) or
              (byte >= 0b10100000 and byte <= 0b10111111) do
    throw({:portals_codec_error, {:truncated, byte_size(other)}})
  end

  defp decode_term(other, _depth, _limits) when is_binary(other),
    do: throw({:portals_codec_error, {:invalid_encoding, :binary.first(other)}})

  defp decode_array(len, _rest, _depth, limits) when len > limits.max_collection_length do
    throw({:portals_codec_error, {:max_length_exceeded, len}})
  end

  defp decode_array(len, rest, depth, limits) do
    {items, rest2} = decode_n(len, rest, depth + 1, limits, [])
    {:ok, items, rest2}
  end

  defp decode_map(len, _rest, _depth, limits) when len > limits.max_collection_length do
    throw({:portals_codec_error, {:max_length_exceeded, len}})
  end

  defp decode_map(len, rest, depth, limits) do
    {map, rest2} = decode_map_pairs(len, rest, depth + 1, limits, %{})
    {:ok, map, rest2}
  end

  defp decode_n(0, rest, _depth, _limits, acc), do: {Enum.reverse(acc), rest}

  defp decode_n(n, bin, depth, limits, acc) do
    case decode_term(bin, depth, limits) do
      {:ok, term, rest} -> decode_n(n - 1, rest, depth, limits, [term | acc])
      {:error, _} = err -> throw({:portals_codec_error, err})
    end
  end

  defp decode_map_pairs(0, rest, _depth, _limits, acc), do: {acc, rest}

  defp decode_map_pairs(n, bin, depth, limits, acc) do
    with {:ok, key, rest1} <- decode_term(bin, depth, limits),
         {:ok, value, rest2} <- decode_term(rest1, depth, limits) do
      decode_map_pairs(n - 1, rest2, depth, limits, Map.put(acc, key, value))
    end
  end

  defp decode_ext(type_code, payload, depth, limits, rest) do
    case TermExtensions.ext_type_name(type_code) do
      {:ok, :bigint} ->
        case TermExtensions.decode_bigint(payload) do
          {:ok, int} -> {:ok, int, rest}
          {:error, reason} -> throw({:portals_codec_error, reason})
        end

      {:ok, :atom} ->
        case TermExtensions.decode_atom(payload) do
          {:ok, atom} -> {:ok, atom, rest}
          {:error, reason} -> throw({:portals_codec_error, reason})
        end

      {:ok, :pid} ->
        case TermExtensions.decode_pid(payload) do
          {:ok, pid} -> {:ok, pid, rest}
          {:error, reason} -> throw({:portals_codec_error, reason})
        end

      {:ok, :reference} ->
        case TermExtensions.decode_reference(payload) do
          {:ok, ref} -> {:ok, ref, rest}
          {:error, reason} -> throw({:portals_codec_error, reason})
        end

      {:ok, :tuple} ->
        case decode_term(payload, depth + 1, limits) do
          {:ok, list, <<>>} when is_list(list) ->
            {:ok, List.to_tuple(list), rest}

          {:ok, _list, extra} ->
            throw({:portals_codec_error, {:trailing_bytes, byte_size(extra)}})

          {:error, reason} ->
            throw({:portals_codec_error, reason})
        end

      {:ok, :improper_list} ->
        case decode_term(payload, depth + 1, limits) do
          {:ok, [proper_part, tail], <<>>} ->
            {:ok, proper_part ++ tail, rest}

          {:ok, _other, <<>>} ->
            throw({:portals_codec_error, {:invalid_extension, :improper_list}})

          {:ok, _list, extra} ->
            throw({:portals_codec_error, {:trailing_bytes, byte_size(extra)}})

          {:error, reason} ->
            throw({:portals_codec_error, reason})
        end

      :error ->
        throw({:portals_codec_error, {:invalid_extension, type_code}})
    end
  end
end
