# Replays the protocol's golden vectors and malformed fixtures against the
# bundled Go SDK, once per codec (see `Portals.Conformance.SDKSuite`).

defmodule PortalsGo.ConformanceTest.Opts do
  @moduledoc false

  def opts(codec) do
    binary = PortalsGo.TestArtifacts.binary("fixture_worker")

    [
      language: "go",
      worker: Portals.Go.worker_opts(binary: binary),
      stdio_worker:
        Portals.Go.worker_opts(
          binary: binary,
          env: [{"PORTALS_TRANSPORT", "stdio"}, {"PORTALS_MAX_CONCURRENCY", "16"}]
        ),
      bad_version_worker:
        Portals.Go.worker_opts(binary: binary, env: [{"PORTALS_PROTOCOL_VERSION", "999"}]),
      codec: codec
    ]
  end
end

defmodule PortalsGo.ConformanceTest.ETF do
  use Portals.Conformance.SDKSuite, PortalsGo.ConformanceTest.Opts.opts(:etf)
end

defmodule PortalsGo.ConformanceTest.MessagePack do
  use Portals.Conformance.SDKSuite, PortalsGo.ConformanceTest.Opts.opts(:msgpack)
end
