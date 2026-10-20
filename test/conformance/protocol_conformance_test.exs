defmodule Portals.Conformance.ProtocolConformanceTest do
  use ExUnit.Case, async: true

  alias Portals.Conformance.Runner

  for {codec, name} <- [{Portals.Codec.ETF, :etf}, {Portals.Codec.MessagePack, :msgpack}] do
    test "#{inspect(codec)} passes every golden vector and #{name} malformed fixture" do
      result = Runner.run(unquote(codec))

      assert result.failed == []

      assert result.passed ==
               length(Runner.golden_vectors()) + length(Runner.malformed_fixtures(unquote(name)))
    end
  end

  test "golden vectors and malformed fixtures are non-empty" do
    assert length(Runner.golden_vectors()) > 0
    assert length(Runner.malformed_fixtures(:etf)) > 0
    assert length(Runner.malformed_fixtures(:msgpack)) > 0
  end
end
