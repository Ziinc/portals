defmodule PortalsPython.WorkerSuiteTest do
  @moduledoc """
  Holds the bundled Python SDK to the same black-box expectations as every
  other language (see `Portals.Conformance.WorkerSuite`), launching its
  fixture worker through `Portals.Python.worker_opts/1` exactly as an application
  would.
  """

  @fixtures Path.expand("../priv/python/tests/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker: Portals.Python.worker_opts(script: Path.join(@fixtures, "run_worker.py"))
end
