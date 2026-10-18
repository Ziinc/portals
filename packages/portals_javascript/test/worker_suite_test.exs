# Holds the bundled JavaScript SDK to the same black-box expectations as
# every other language (see `Portals.Conformance.WorkerSuite`), once per
# runtime, launching the fixture worker through
# `Portals.JavaScript.worker_opts/1` exactly as an application would.
for runtime <- Portals.JavaScript.runtimes() do
  defmodule Module.concat(PortalsJavaScript.WorkerSuiteTest, Macro.camelize(to_string(runtime))) do
    @fixtures Path.expand("../priv/javascript/portals-worker/test/fixtures", __DIR__)

    use Portals.Conformance.WorkerSuite,
      moduletag: [runtime: runtime],
      worker:
        Portals.JavaScript.worker_opts(
          script: Path.join(@fixtures, "run_worker.js"),
          runtime: runtime
        )
  end
end
