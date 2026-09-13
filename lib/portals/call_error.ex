defmodule Portals.CallError do
  @moduledoc "Raised by `Portals.call!/5` (and `Portals.Connection.call!/5`) on a failed call."

  defexception [:error]

  @impl true
  def message(%{error: error}), do: "#{error.kind}: #{error.message}"
end
