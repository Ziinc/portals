defmodule Portals.Integration.GoWorkerTest do
  @moduledoc """
  The bundled Go SDK is held to exactly the same black-box expectations as
  the reference Python SDK (see `Portals.Fixtures.WorkerSuite`). The
  launcher script builds the fixture worker binary on first use.
  """

  use Portals.Fixtures.WorkerSuite,
    runtime: "sh",
    script: "sdk/go/test/fixtures/run_worker.sh"
end
