defmodule Portals.Codec.ETFBenchTest do
  use ExUnit.Case, async: true

  alias Portals.Codec.ETFBench
  alias Portals.Conformance.Runner

  @limits Portals.Protocol.default_limits()

  test "every golden vector round-trips" do
    for {name, term} <- Runner.golden_vectors() do
      envelope = [Portals.Protocol.frame_tag(:return), 1, term]
      assert {:ok, bytes} = ETFBench.encode(envelope, @limits)
      assert {:ok, ^envelope, <<>>} = ETFBench.decode(bytes, @limits), "vector #{name}"
    end
  end

  test "returns trailing bytes" do
    {:ok, bytes} = ETFBench.encode([4, 1, :ok], @limits)
    assert {:ok, [4, 1, :ok], "rest"} = ETFBench.decode(bytes <> "rest", @limits)
  end

  test "rejects atoms the BEAM has not seen, malformed and oversized frames" do
    unknown_atom = <<131, 119, 20, "portals_never_seen_1">>
    assert {:error, {:invalid_encoding, :etf}} = ETFBench.decode(unknown_atom, @limits)
    assert {:error, {:invalid_encoding, :etf}} = ETFBench.decode(<<131, 255>>, @limits)

    small = %{@limits | max_frame_size: 16}

    assert {:error, {:max_size_exceeded, _}} =
             ETFBench.encode([4, 1, String.duplicate("x", 32)], small)

    assert {:error, {:max_size_exceeded, 32}} = ETFBench.decode(:binary.copy(<<0>>, 32), small)
  end
end
