defmodule Portals.Codec.ETFTest do
  use ExUnit.Case, async: true

  alias Portals.Codec.ETF
  alias Portals.Conformance.Runner

  @limits Portals.Protocol.default_limits()

  test "every golden vector round-trips" do
    for {name, term} <- Runner.golden_vectors() do
      envelope = [Portals.Protocol.frame_tag(:return), 1, term]
      assert {:ok, bytes} = ETF.encode(envelope, @limits)
      assert {:ok, ^envelope, <<>>} = ETF.decode(bytes, @limits), "vector #{name}"
    end
  end

  test "returns trailing bytes" do
    {:ok, bytes} = ETF.encode([4, 1, :ok], @limits)
    assert {:ok, [4, 1, :ok], "rest"} = ETF.decode(bytes <> "rest", @limits)
  end

  test "rejects atoms the BEAM has not seen, malformed and oversized frames" do
    unknown_atom = <<131, 119, 20, "portals_never_seen_1">>
    assert {:error, {:invalid_encoding, :etf}} = ETF.decode(unknown_atom, @limits)
    assert {:error, {:invalid_encoding, :etf}} = ETF.decode(<<131, 255>>, @limits)

    small = %{@limits | max_frame_size: 16}

    assert {:error, {:max_size_exceeded, _}} =
             ETF.encode([4, 1, String.duplicate("x", 32)], small)

    assert {:error, {:max_size_exceeded, 32}} = ETF.decode(:binary.copy(<<0>>, 32), small)
  end

  test "encoding enforces the nesting and collection limits, like MessagePack" do
    limits = %{@limits | max_nesting_depth: 3, max_collection_length: 4}

    assert {:ok, _} = ETF.encode([4, 1, [[1]]], limits)
    assert {:error, {:max_depth_exceeded, 4}} = ETF.encode([4, 1, [[[1]]]], limits)
    assert {:error, {:max_length_exceeded, 5}} = ETF.encode([4, 1, [1, 2, 3, 4, 5]], limits)
    assert {:error, {:max_length_exceeded, 5}} = ETF.encode([4, 1, {1, 2, 3, 4, 5}], limits)

    assert {:error, {:max_length_exceeded, 5}} =
             ETF.encode([4, 1, Map.new(1..5, &{&1, &1})], limits)

    assert {:ok, _} = ETF.encode([4, 1, [1 | 2]], limits)
  end

  test "encoding rejects values no SDK can represent" do
    for value <- [fn -> :ok end, <<1::3>>, hd(Port.list())] do
      assert {:error, {:invalid_encoding, {:unsupported, ^value}}} =
               ETF.encode([4, 1, value], @limits)
    end
  end
end
