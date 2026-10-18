defmodule Portals.Integration.PhpWorkerTest do
  @moduledoc """
  The bundled PHP SDK is held to exactly the same black-box expectations as
  the reference Python SDK (see `Portals.Fixtures.WorkerSuite`).
  """

  use Portals.Fixtures.WorkerSuite,
    runtime: "php",
    script: "sdk/php/test/fixtures/run_worker.php"
end
