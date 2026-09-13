defmodule Portals.HandshakeTest do
  use ExUnit.Case, async: true

  alias Portals.Handshake
  alias Portals.Protocol

  test "accepts a matching protocol version" do
    hello = Handshake.build_hello("python3.11", 16, 4, ["callbacks", "streams"])
    assert {:ok, %Handshake.Hello{protocol_version: v}} = Handshake.negotiate(hello)
    assert v == Protocol.version()
  end

  test "deterministically rejects a mismatched protocol version" do
    hello = [Protocol.frame_tag(:hello), Protocol.version() + 1, "python3.11", 16, 4, []]

    assert {:error, {:protocol_version_mismatch, expected, actual}} = Handshake.negotiate(hello)
    assert expected == Protocol.version()
    assert actual == Protocol.version() + 1
  end

  test "rejects a malformed HELLO shape" do
    assert {:error, {:malformed_hello, _}} = Handshake.negotiate([Protocol.frame_tag(:hello)])
  end
end
