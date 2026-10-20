# Replays the protocol's golden vectors and malformed fixtures against the
# bundled JavaScript SDK on each runtime, once per codec (see
# `Portals.Conformance.SDKSuite`).
defmodule PortalsJavaScript.ConformanceTest.Opts do
  @fixtures Path.expand("../priv/javascript/portals-worker/test/fixtures", __DIR__)

  def opts(runtime, codec) do
    [
      moduletag: [runtime: runtime],
      language: "javascript (#{runtime})",
      worker:
        Portals.JavaScript.worker_opts(
          script: Path.join(@fixtures, "run_worker.js"),
          runtime: runtime
        ),
      stdio_worker:
        Portals.JavaScript.worker_opts(
          script: Path.join(@fixtures, "run_worker_stdio.js"),
          runtime: runtime
        ),
      bad_version_worker:
        Portals.JavaScript.worker_opts(
          script: Path.join(@fixtures, "run_worker.js"),
          runtime: runtime,
          env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
        ),
      codec: codec
    ]
  end
end

for runtime <- Portals.JavaScript.runtimes(),
    {codec, suffix} <- [etf: "ETF", msgpack: "MessagePack"] do
  defmodule Module.concat([
              PortalsJavaScript.ConformanceTest,
              Macro.camelize(to_string(runtime)),
              suffix
            ]) do
    use Portals.Conformance.SDKSuite,
        PortalsJavaScript.ConformanceTest.Opts.opts(runtime, codec)
  end
end
