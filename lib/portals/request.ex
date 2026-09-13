defmodule Portals.Request do
  @moduledoc """
  A reference to one in-flight or completed asynchronous call, returned by
  `Portals.async/5` (or `Portals.Connection.async/5`). Pass it to
  `Portals.await/2` and `Portals.cancel/2`.
  """

  @enforce_keys [:connection, :id]
  defstruct [:connection, :id]

  @type t :: %__MODULE__{connection: pid, id: non_neg_integer}
end
