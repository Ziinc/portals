# Replays the protocol's golden vectors and malformed fixtures against the
# bundled JavaScript SDK on each runtime (see `Portals.Conformance.SDKSuite`).
for runtime <- Portals.JavaScript.runtimes() do
  defmodule Module.concat(PortalsJavaScript.ConformanceTest, Macro.camelize(to_string(runtime))) do
    @fixtures Path.expand("../priv/javascript/portals-worker/test/fixtures", __DIR__)

    use Portals.Conformance.SDKSuite,
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
        )
  end
end
