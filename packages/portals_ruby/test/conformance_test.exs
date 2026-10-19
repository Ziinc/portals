# Replays the protocol's golden vectors and malformed fixtures against the
# bundled Ruby SDK, once per codec (see `Portals.Conformance.SDKSuite`).

defmodule PortalsRuby.ConformanceTest.Opts do
  @fixtures Path.expand("../priv/ruby/test/fixtures", __DIR__)

  def opts(codec) do
    [
      language: "ruby",
      worker: Portals.Ruby.worker_opts(script: Path.join(@fixtures, "run_worker.rb")),
      stdio_worker: Portals.Ruby.worker_opts(script: Path.join(@fixtures, "run_worker_stdio.rb")),
      bad_version_worker:
        Portals.Ruby.worker_opts(
          script: Path.join(@fixtures, "run_worker.rb"),
          env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
        ),
      codec: codec
    ]
  end
end

defmodule PortalsRuby.ConformanceTest.ETF do
  use Portals.Conformance.SDKSuite, PortalsRuby.ConformanceTest.Opts.opts(:etf)
end

defmodule PortalsRuby.ConformanceTest.MessagePack do
  use Portals.Conformance.SDKSuite, PortalsRuby.ConformanceTest.Opts.opts(:msgpack)
end
