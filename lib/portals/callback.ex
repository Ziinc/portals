defmodule Portals.Callback do
  @moduledoc """
  Introspection helper for code running inside a callback handler
  (invoked by `Portals.Connection` in response to a worker's `CALLBACK`
  frame). See protocol/v1.md section 8 for the reentrancy-depth model.
  """

  @doc """
  The current reentrancy depth, or `0` outside of any callback handler.
  Any `Portals.call/5`/`async/5` issued while this is non-zero
  automatically carries it forward so the worker can correctly report
  its own next nesting level.
  """
  @spec depth() :: non_neg_integer
  def depth, do: Process.get(:portals_callback_depth, 0)
end
