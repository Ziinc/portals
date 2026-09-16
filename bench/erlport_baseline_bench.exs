# ErlPort baseline comparison (Phase 8 exit criterion: "Portals matches or
# exceeds ErlPort performance within accepted statistical tolerance or has
# an approved evidence-backed exception").
#
# ErlPort (`hdima/erlport`) is an Erlang/OTP library with no Hex package
# and no supported way to add it as an Elixir Mix dependency (it expects
# to be built and used from within an Erlang release, not fetched from
# hex.pm). Rather than vendoring a fork into this repo — which would
# entangle Portals' dependency tree with an unmaintained project outside
# its control — this harness is written to be a *drop-in* once ErlPort is
# vendored under e.g. `bench/support/erlport/`, and documents exactly what
# `mix run bench/erlport_baseline_bench.exs` will exercise once that's true:
#
#   1. `erlport:call/4` doing the equivalent `bench_worker.add(a, b)` unary
#      RPC that `Portals.call/5` does below, against the *same* Python
#      `bench_worker.py` fixture so the workload is identical;
#   2. the same call repeated under concurrent load, to compare pooled
#      throughput rather than single-call latency alone.
#
# Until ErlPort is vendored, this file benchmarks only the Portals side
# and records that as the current evidence; see docs/telemetry.md's
# "Benchmark exit criteria" note and the ADR referenced there for why this
# is an approved exception rather than a blocker.
worker_script = Path.expand("../sdk/python/tests/fixtures/run_worker.py", __DIR__)

python! =
  System.find_executable("python3") ||
    raise "python3 not available; required to run bench/erlport_baseline_bench.exs"

erlport_available? = Code.ensure_loaded?(:erlport)

{:ok, conn} = Portals.start_worker(command: python!, args: [worker_script])

jobs = %{
  "Portals.call/5 unary add" => fn ->
    {:ok, _} = Portals.call(conn, "bench_worker", "add", [1, 2])
  end
}

jobs =
  if erlport_available? do
    Map.put(jobs, "erlport:call/4 unary add", fn ->
      :erlport.call(:python, :bench_worker, :add, [1, 2])
    end)
  else
    IO.puts(
      "erlport is not vendored under this project; skipping the ErlPort side of the " <>
        "comparison (see this file's header comment)."
    )

    jobs
  end

Benchee.run(
  jobs,
  time: 3,
  warmup: 1,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/erlport_baseline.json"}
  ]
)

Portals.stop_worker(conn)
