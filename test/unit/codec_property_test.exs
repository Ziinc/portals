defmodule Portals.Codec.MessagePackPropertyTest do
  @moduledoc """
  Property-based / fuzz coverage for the MessagePack codec (Phase 9).

  Two properties are checked:

    * arbitrary well-typed terms survive an encode/decode round trip;
    * arbitrary byte sequences never crash the decoder — they always
      return `{:ok, _, _}` or `{:error, _}`, never raise or hang.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Portals.Codec.MessagePack
  alias Portals.Protocol

  @limits Protocol.default_limits()

  defp term_generator(depth \\ 0) do
    leaf =
      one_of([
        constant(nil),
        boolean(),
        integer(-1_000_000..1_000_000),
        float(min: -1.0e6, max: 1.0e6),
        string(:printable, max_length: 32),
        member_of([:ok, :error, :some_atom, :unicode_é])
      ])

    if depth >= 3 do
      leaf
    else
      one_of([
        leaf,
        list_of(term_generator(depth + 1), max_length: 4),
        map_of(string(:printable, max_length: 8), term_generator(depth + 1), max_length: 4)
      ])
    end
  end

  property "arbitrary terms survive an encode/decode round trip" do
    check all(term <- term_generator()) do
      assert {:ok, bytes} = MessagePack.encode([term], @limits)
      assert {:ok, [decoded], <<>>} = MessagePack.decode(bytes, @limits)
      assert decoded == term
    end
  end

  property "the decoder never raises on arbitrary bytes" do
    check all(bytes <- binary(max_length: 64)) do
      result = MessagePack.decode(bytes, @limits)
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end

  property "the decoder never raises on a well-formed header with arbitrary trailing bytes" do
    check all(tag <- integer(0..255), tail <- binary(max_length: 32)) do
      result = MessagePack.decode(<<tag, tail::binary>>, @limits)
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end

  test "every documented malformed fixture is rejected without raising" do
    fixtures = Code.eval_file("protocol/malformed/fixtures.exs") |> elem(0)

    for {name, bytes, _expected_shape} <- fixtures do
      assert match?({:error, _}, MessagePack.decode(bytes, @limits)),
             "fixture #{name} did not decode to an error"
    end
  end
end
