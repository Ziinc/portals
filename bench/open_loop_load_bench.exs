# Open-loop, fixed-arrival-rate load test (Phase 8), as distinct from
# Benchee's closed-loop "as fast as possible" benchmarks above: calls are
# fired on a fixed schedule regardless of how long earlier calls take, so
# queueing/backpressure behavior under a target rate is visible even when
# the system can't keep up.
#
#   mix run bench/open_loop_load_bench.exs
worker_script = Path.expand("../sdk/python/tests/fixtures/run_worker.py", __DIR__)

python! =
  System.find_executable("python3") ||
    raise "python3 not available; required to run bench/open_loop_load_bench.exs"

{:ok, pool} =
  Portals.start_pool(command: python!, args: [worker_script], size: 4, max_overflow: 4)

arrival_rate_per_sec = 500
duration_ms = 3_000
interval_us = div(1_000_000, arrival_rate_per_sec)

parent = self()
start = System.monotonic_time(:millisecond)

fire = fn fire, sent ->
  now = System.monotonic_time(:millisecond)

  if now - start >= duration_ms do
    sent
  else
    Task.start(fn ->
      call_start = System.monotonic_time()
      result = Portals.Pool.call(pool, "bench_worker", "add", [1, 2], timeout: 2_000)
      latency_us = System.convert_time_unit(System.monotonic_time() - call_start, :native, :microsecond)
      send(parent, {:done, result, latency_us})
    end)

    Process.sleep(div(interval_us, 1000))
    fire.(fire, sent + 1)
  end
end

sent = fire.(fire, 0)

results =
  for _ <- 1..sent do
    receive do
      {:done, result, latency_us} -> {result, latency_us}
    after
      5_000 -> {:timeout, nil}
    end
  end

ok_count = Enum.count(results, fn {r, _} -> match?({:ok, _}, r) end)
latencies = for {{:ok, _}, l} <- results, do: l
latencies_sorted = Enum.sort(latencies)

percentile = fn sorted, p ->
  case sorted do
    [] -> 0
    _ -> Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))
  end
end

IO.puts("target rate: #{arrival_rate_per_sec}/s over #{duration_ms}ms")
IO.puts("sent: #{sent}, succeeded: #{ok_count}, failed: #{sent - ok_count}")
IO.puts("p50 latency: #{percentile.(latencies_sorted, 0.50)} us")
IO.puts("p99 latency: #{percentile.(latencies_sorted, 0.99)} us")

Portals.Pool.stop(pool)
