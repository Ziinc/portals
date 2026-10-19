defmodule PortalsGo.WorkerSuiteTest do
  @moduledoc """
  Holds the bundled Go SDK to the same black-box expectations as every
  other language (see `Portals.Conformance.WorkerSuite`), launching its
  fixture worker through `Portals.Go.worker_opts/1` exactly as an application
  would.
  """

  use Portals.Conformance.WorkerSuite,
    worker: Portals.Go.worker_opts(binary: PortalsGo.TestArtifacts.binary("fixture_worker"))
end
