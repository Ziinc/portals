# Unix-domain-socket vs stdio transport comparison, both driving the same
# Python bench_worker.py so only the transport differs (Phase 8).
#
#   mix run bench/transport_comparison_bench.exs
unix_worker_script = Path.expand("../sdk/python/tests/fixtures/run_worker.py", __DIR__)
stdio_worker_script = Path.expand("../sdk/python/tests/fixtures/run_worker_stdio.py", __DIR__)

python! =
  System.find_executable("python3") ||
    raise "python3 not available; required to run bench/transport_comparison_bench.exs"

{:ok, unix_conn} =
  Portals.start_worker(command: python!, args: [unix_worker_script], transport: :unix)

{:ok, stdio_conn} =
  Portals.start_worker(command: python!, args: [stdio_worker_script], transport: :stdio)

Benchee.run(
  %{
    "unix socket call" => fn ->
      {:ok, _} = Portals.call(unix_conn, "bench_worker", "add", [1, 2])
    end,
    "stdio call" => fn ->
      {:ok, _} = Portals.call(stdio_conn, "bench_worker", "add", [1, 2])
    end
  },
  time: 3,
  warmup: 1,
  formatters: [Benchee.Formatters.Console, {Benchee.Formatters.JSON, file: "bench/results/transport_comparison.json"}]
)

Portals.stop_worker(unix_conn)
Portals.stop_worker(stdio_conn)
