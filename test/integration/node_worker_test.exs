defmodule Portals.Integration.NodeWorkerTest do
  @moduledoc """
  Phase 7: the bundled Node.js SDK is held to exactly the same black-box
  expectations as the reference Python SDK (see
  `Portals.Fixtures.WorkerSuite`).
  """

  use Portals.Fixtures.WorkerSuite,
    runtime: "node",
    script: "sdk/node/test/fixtures/run_worker.js"
end
