# Open-loop, fixed-arrival-rate load test, as distinct from the other
# scripts' closed-loop "as fast as possible" Benchee runs: calls are fired
# on a fixed schedule regardless of how long earlier calls take, so
# queueing/backpressure behavior under a target rate is visible even when
# the pool can't keep up.
#
#     mix run open_loop_load.exs
target = Bench.Targets.portals(transport: :unix, size: 4)
handle = target.start.()

arrival_rate_per_sec = 500
duration_ms = 3_000
interval_ms = max(1, div(1_000, arrival_rate_per_sec))

parent = self()
start = System.monotonic_time(:millisecond)

fire = fn fire, sent ->
  now = System.monotonic_time(:millisecond)

  if now - start >= duration_ms do
    sent
  else
    Task.start(fn ->
      call_start = System.monotonic_time()
      result =
        try do
          {:ok, target.call.(handle, "add", [1, 2])}
        rescue
          e -> {:error, e}
        end

      latency_us =
        System.convert_time_unit(System.monotonic_time() - call_start, :native, :microsecond)

      send(parent, {:done, result, latency_us})
    end)

    Process.sleep(interval_ms)
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

target.stop.(handle)
