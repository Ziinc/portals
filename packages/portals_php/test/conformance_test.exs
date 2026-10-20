# Replays the protocol's golden vectors and malformed fixtures against the
# bundled PHP SDK, once per codec (see `Portals.Conformance.SDKSuite`).

defmodule PortalsPHP.ConformanceTest.Opts do
  @fixtures Path.expand("../priv/php/test/fixtures", __DIR__)

  def opts(codec) do
    [
      language: "php",
      worker: Portals.PHP.worker_opts(script: Path.join(@fixtures, "run_worker.php")),
      stdio_worker: Portals.PHP.worker_opts(script: Path.join(@fixtures, "run_worker_stdio.php")),
      bad_version_worker:
        Portals.PHP.worker_opts(
          script: Path.join(@fixtures, "run_worker.php"),
          env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
        ),
      codec: codec
    ]
  end
end

defmodule PortalsPHP.ConformanceTest.ETF do
  use Portals.Conformance.SDKSuite, PortalsPHP.ConformanceTest.Opts.opts(:etf)
end

defmodule PortalsPHP.ConformanceTest.MessagePack do
  use Portals.Conformance.SDKSuite, PortalsPHP.ConformanceTest.Opts.opts(:msgpack)
end
