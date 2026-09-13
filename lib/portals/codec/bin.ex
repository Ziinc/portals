defmodule Portals.Codec.Bin do
  @moduledoc """
  Explicit wrapper marking a value as the MessagePack `bin` type rather
  than `str`. Plain Elixir binaries encode as UTF-8 strings by default;
  wrap arbitrary byte payloads (image data, serialized blobs, and other
  non-text binaries) in `%Portals.Codec.Bin{}` to force `bin` encoding.
  """

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: binary}
end
