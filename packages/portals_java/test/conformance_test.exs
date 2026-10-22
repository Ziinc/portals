# Replays the protocol's golden vectors and malformed fixtures against the
# bundled Java SDK, once per codec (see `Portals.Conformance.SDKSuite`).

defmodule PortalsJava.ConformanceTest.Opts do
  @moduledoc false

  def opts(codec) do
    [
      language: "java",
      worker: worker_opts("portals.fixtures.RunWorker"),
      stdio_worker: worker_opts("portals.fixtures.RunWorkerStdio"),
      bad_version_worker:
        worker_opts("portals.fixtures.RunWorker", env: [{"PORTALS_PROTOCOL_VERSION", "999"}]),
      codec: codec
    ]
  end

  defp worker_opts(main, extra \\ []) do
    Portals.Java.worker_opts(
      [
        main: main,
        classpath: [PortalsJava.TestArtifacts.dir("fixtures")],
        java_args: PortalsJava.TestArtifacts.java_args()
      ] ++ extra
    )
  end
end

defmodule PortalsJava.ConformanceTest.ETF do
  use Portals.Conformance.SDKSuite, PortalsJava.ConformanceTest.Opts.opts(:etf)
end

defmodule PortalsJava.ConformanceTest.MessagePack do
  use Portals.Conformance.SDKSuite, PortalsJava.ConformanceTest.Opts.opts(:msgpack)
end
