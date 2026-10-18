defmodule PortalsNode.WorkerSuiteTest do
  @moduledoc """
  Holds the bundled Node SDK to the same black-box expectations as every
  other language (see `Portals.Conformance.WorkerSuite`), launching its
  fixture worker through `Portals.Node.worker_opts/1` exactly as an application
  would.
  """

  @fixtures Path.expand("../priv/node/portals-worker/test/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker: Portals.Node.worker_opts(script: Path.join(@fixtures, "run_worker.js"))
end
