# Replays the protocol's golden vectors and malformed fixtures against the
# bundled Python SDK, once per codec (see `Portals.Conformance.SDKSuite`).

defmodule PortalsPython.ConformanceTest.Opts do
  @fixtures Path.expand("../priv/python/tests/fixtures", __DIR__)

  def opts(codec) do
    [
      language: "python",
      worker: Portals.Python.worker_opts(script: Path.join(@fixtures, "run_worker.py")),
      stdio_worker:
        Portals.Python.worker_opts(script: Path.join(@fixtures, "run_worker_stdio.py")),
      bad_version_worker:
        Portals.Python.worker_opts(script: Path.join(@fixtures, "run_worker_bad_version.py")),
      codec: codec
    ]
  end
end

defmodule PortalsPython.ConformanceTest.ETF do
  use Portals.Conformance.SDKSuite, PortalsPython.ConformanceTest.Opts.opts(:etf)
end

defmodule PortalsPython.ConformanceTest.MessagePack do
  use Portals.Conformance.SDKSuite, PortalsPython.ConformanceTest.Opts.opts(:msgpack)
end
