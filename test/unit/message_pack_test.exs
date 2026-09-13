defmodule Portals.Codec.MessagePackTest do
  use ExUnit.Case, async: true

  alias Portals.Codec.MessagePack
  alias Portals.Codec.Bin
  alias Portals.Protocol

  @limits Protocol.default_limits()

  defp round_trip(envelope) do
    {:ok, bytes} = MessagePack.encode(envelope, @limits)
    {:ok, decoded, <<>>} = MessagePack.decode(bytes, @limits)
    decoded
  end

  test "encodes nil/bool/int/float exactly" do
    assert MessagePack.encode([nil], @limits) == {:ok, <<0x91, 0xC0>>}
    assert MessagePack.encode([true], @limits) == {:ok, <<0x91, 0xC3>>}
    assert MessagePack.encode([false], @limits) == {:ok, <<0x91, 0xC2>>}
    assert MessagePack.encode([0], @limits) == {:ok, <<0x91, 0x00>>}
    assert MessagePack.encode([-1], @limits) == {:ok, <<0x91, 0xFF>>}
  end

  test "round trips small ints, negative ints, and bigints" do
    for n <- [0, 1, 127, 128, 255, 256, 65535, 65536, -1, -32, -33, -128, -129, -32768, -32769] do
      assert round_trip([n]) == [n]
    end

    huge = 170_141_183_460_469_231_731_687_303_715_884_105_728
    assert round_trip([huge]) == [huge]
    assert round_trip([-huge]) == [-huge]
  end

  test "round trips floats" do
    assert round_trip([1.5]) == [1.5]
    assert round_trip([0.0]) == [0.0]
  end

  test "round trips strings and explicit binaries distinctly" do
    assert round_trip(["hello"]) == ["hello"]
    assert round_trip([%Bin{data: <<0, 1, 2>>}]) == [%Bin{data: <<0, 1, 2>>}]
  end

  test "round trips atoms without creating new ones" do
    assert round_trip([:ok]) == [:ok]
  end

  test "round trips tuples, nested maps, and lists" do
    term = {:ok, %{"a" => [1, 2, {:x, :y}]}, nil}
    assert round_trip([term]) == [term]
  end

  test "round trips a local PID" do
    pid = self()
    assert round_trip([pid]) == [pid]
  end

  test "round trips a reference" do
    ref = make_ref()
    assert round_trip([ref]) == [ref]
  end

  test "round trips an improper list" do
    assert round_trip([[1, 2 | :tail]]) == [[1, 2 | :tail]]
  end

  test "rejects an atom that does not already exist without creating it" do
    fresh_atom_text = "portals_conformance_never_defined_#{System.unique_integer([:positive])}"
    payload = <<0xC7, byte_size(fresh_atom_text), 1, fresh_atom_text::binary>>
    envelope_bytes = <<0x91>> <> payload

    assert {:error, {:unsafe_atom, ^fresh_atom_text}} =
             MessagePack.decode(envelope_bytes, @limits)

    assert_raise ArgumentError, fn -> String.to_existing_atom(fresh_atom_text) end
  end

  test "enforces max_collection_length on decode" do
    tight_limits = %{@limits | max_collection_length: 2}
    {:ok, bytes} = MessagePack.encode([[1, 2, 3]], @limits)
    assert {:error, {:max_length_exceeded, 3}} = MessagePack.decode(bytes, tight_limits)
  end

  test "enforces max_frame_size on encode and decode" do
    tight_limits = %{@limits | max_frame_size: 4}

    assert {:error, {:max_size_exceeded, _}} =
             MessagePack.encode(["much too long a string"], tight_limits)
  end

  test "decoding a truncated frame fails instead of raising" do
    assert {:error, {:truncated, _}} = MessagePack.decode(<<0x91>>, @limits)
  end
end
