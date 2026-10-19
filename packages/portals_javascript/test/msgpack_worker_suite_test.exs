# The black-box worker suite again, over the MessagePack codec, once per
# runtime (worker_suite_test.exs runs it over the default, ETF).
for runtime <- Portals.JavaScript.runtimes() do
  defmodule Module.concat(
              PortalsJavaScript.MsgpackWorkerSuiteTest,
              Macro.camelize(to_string(runtime))
            ) do
    @fixtures Path.expand("../priv/javascript/portals-worker/test/fixtures", __DIR__)

    use Portals.Conformance.WorkerSuite,
      moduletag: [runtime: runtime],
      worker:
        Portals.JavaScript.worker_opts(
          script: Path.join(@fixtures, "run_worker.js"),
          runtime: runtime,
          codec: :msgpack
        )
  end
end
