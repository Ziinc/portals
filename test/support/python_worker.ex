defmodule Portals.Test.PythonWorker do
  @moduledoc """
  Launch options for the Python SDK's fixture workers, used by core's own
  integration tests.

  Core cannot depend on `portals_python` (that package depends on core), so
  this mirrors what `Portals.Python.worker_opts/1` does: put the SDK in the
  monorepo's `packages/portals_python` on `PYTHONPATH`.
  """

  @sdk Path.expand("../../packages/portals_python/priv/python", __DIR__)

  def opts(fixture, extra \\ []) do
    python =
      System.find_executable("python3") || System.find_executable("python") ||
        raise "python3 not available; required for Portals integration tests"

    [
      command: python,
      args: [Path.join([@sdk, "tests", "fixtures", fixture])],
      env: [{"PYTHONPATH", @sdk}]
    ] ++ extra
  end
end
