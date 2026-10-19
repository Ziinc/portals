defmodule PortalsPython.ETFWorkerSuiteTest do
  @moduledoc """
  The same black-box suite over the benchmark-only ETF codec
  (`Portals.Codec.ETFBench`, `PORTALS_CODEC=etf`), so the benchmark suite's
  ETF comparison measures a path that behaves exactly like MessagePack.
  """

  @fixtures Path.expand("../priv/python/tests/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker:
      Portals.Python.worker_opts(
        script: Path.join(@fixtures, "run_worker.py"),
        codec: Portals.Codec.ETFBench,
        env: [{"PORTALS_CODEC", "etf"}]
      )
end
