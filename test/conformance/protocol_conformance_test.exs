defmodule Portals.Conformance.ProtocolConformanceTest do
  use ExUnit.Case, async: true

  alias Portals.Conformance.Runner
  alias Portals.Codec.MessagePack

  test "the reference MessagePack codec passes every golden vector and malformed fixture" do
    result = Runner.run(MessagePack)

    assert result.failed == []
    assert result.passed == length(Runner.golden_vectors()) + length(Runner.malformed_fixtures())
  end

  test "golden vectors and malformed fixtures are non-empty" do
    assert length(Runner.golden_vectors()) > 0
    assert length(Runner.malformed_fixtures()) > 0
  end
end
