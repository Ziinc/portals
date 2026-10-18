defmodule PortalsPHP.WorkerSuiteTest do
  @moduledoc """
  Holds the bundled PHP SDK to the same black-box expectations as every
  other language (see `Portals.Conformance.WorkerSuite`), launching its
  fixture worker through `Portals.PHP.worker_opts/1` exactly as an application
  would.
  """

  @fixtures Path.expand("../priv/php/test/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker: Portals.PHP.worker_opts(script: Path.join(@fixtures, "run_worker.php"))
end
