defmodule PortalsPython.ConformanceTest do
  @moduledoc """
  Replays the protocol's golden vectors and malformed fixtures against the
  bundled Python SDK (see `Portals.Conformance.SDKSuite`).
  """

  @fixtures Path.expand("../priv/python/tests/fixtures", __DIR__)

  use Portals.Conformance.SDKSuite,
    language: "python",
    worker: Portals.Python.worker_opts(script: Path.join(@fixtures, "run_worker.py")),
    stdio_worker: Portals.Python.worker_opts(script: Path.join(@fixtures, "run_worker_stdio.py")),
    bad_version_worker:
      Portals.Python.worker_opts(script: Path.join(@fixtures, "run_worker_bad_version.py"))
end
