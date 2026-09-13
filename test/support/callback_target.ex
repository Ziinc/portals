defmodule Portals.Fixtures.CallbackTarget do
  @moduledoc "A BEAM-side callback target used by the Python integration tests."

  def double(n), do: n * 2

  def boom, do: raise("callback target exploded")

  def echo(value), do: value
end
