defmodule Portals.ProtocolTest do
  use ExUnit.Case, async: true

  alias Portals.Protocol

  test "every frame tag round trips through frame_name/1" do
    for {name, tag} <- [
          {:hello, 1},
          {:ready, 2},
          {:call, 3},
          {:return, 4},
          {:error, 5},
          {:cancel, 6},
          {:callback, 7},
          {:callback_return, 8},
          {:callback_error, 9},
          {:message, 10},
          {:stream_data, 11},
          {:credit, 12},
          {:half_close, 13},
          {:ping, 14},
          {:pong, 15},
          {:shutdown, 16}
        ] do
      assert Protocol.frame_tag(name) == tag
      assert Protocol.frame_name(tag) == {:ok, name}
    end
  end

  test "unknown tags are rejected" do
    assert Protocol.frame_name(999) == :error
  end

  test "validate_envelope enforces arity" do
    assert {:ok, {:cancel, [1]}} = Protocol.validate_envelope([Protocol.frame_tag(:cancel), 1])
    assert {:error, {:bad_arity, 0}} = Protocol.validate_envelope([Protocol.frame_tag(:cancel)])

    assert {:error, {:bad_arity, 2}} =
             Protocol.validate_envelope([Protocol.frame_tag(:cancel), 1, 2])
  end

  test "shutdown allows an optional trailing field" do
    assert {:ok, {:shutdown, []}} = Protocol.validate_envelope([Protocol.frame_tag(:shutdown)])

    assert {:ok, {:shutdown, ["reason"]}} =
             Protocol.validate_envelope([Protocol.frame_tag(:shutdown), "reason"])
  end

  test "rejects an unknown frame tag" do
    assert {:error, {:unknown_frame_tag, 999}} = Protocol.validate_envelope([999, 1, 2])
  end

  test "rejects an empty envelope" do
    assert {:error, :empty_envelope} = Protocol.validate_envelope([])
  end
end
