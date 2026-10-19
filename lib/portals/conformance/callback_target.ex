defmodule Portals.Fixtures.CallbackTarget do
  @moduledoc """
  The BEAM-side callback target the shared conformance suites call back
  into (as `Elixir.Portals.Fixtures.CallbackTarget`) from every SDK's
  `bench_worker` fixture.

  Callback targets must already exist as atoms before a worker can name
  them, so `Portals.Conformance.WorkerSuite` users load this module in
  their `test_helper.exs` with `Code.ensure_loaded!/1`.
  """

  def double(n), do: n * 2

  def boom, do: raise("callback target exploded")

  def echo(value), do: value
end
