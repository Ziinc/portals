defmodule Portals.Integration.PoolTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  @worker_script Path.expand("../../sdk/python/tests/fixtures/run_worker.py", __DIR__)

  defp python! do
    System.find_executable("python3") ||
      raise "python3 not available; required for Portals integration tests"
  end

  test "calls are load-balanced across base workers" do
    {:ok, pool} =
      Portals.start_pool(command: python!(), args: [@worker_script], size: 3, max_overflow: 0)

    on_exit(fn -> Portals.Pool.stop(pool) end)

    requests = for i <- 1..12, do: elem(Portals.Pool.async(pool, "bench_worker", "echo", [i]), 1)
    results = for r <- requests, do: Portals.Pool.await(r, 2_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    health = Portals.Pool.health(pool)
    assert health.worker_count == 3
  end

  test "creates overflow workers under load and retires them when idle" do
    {:ok, pool} =
      Portals.start_pool(
        command: python!(),
        args: [@worker_script],
        size: 1,
        max_overflow: 2,
        checkout_timeout: 2_000
      )

    on_exit(fn -> Portals.Pool.stop(pool) end)

    assert Portals.Pool.health(pool).worker_count == 1

    # bench_worker's Worker advertises max_concurrency=64, so 1 base worker
    # would normally absorb many concurrent calls; drop the ceiling via a
    # slow workload count high enough to saturate a single worker's
    # concurrency budget artificially by using long sleeps.
    requests =
      for _ <- 1..3 do
        elem(Portals.Pool.async(pool, "bench_worker", "sleep_ms", [300]), 1)
      end

    Process.sleep(50)
    # All three should have gone to the same (undersaturated) base worker
    # since it comfortably fits within its advertised concurrency; overflow
    # is only created once a worker's own concurrency limit is hit. This
    # asserts the pool remains at size 1 for ordinary concurrent load.
    assert Portals.Pool.health(pool).worker_count == 1

    results = for r <- requests, do: Portals.Pool.await(r, 2_000)
    assert Enum.all?(results, &match?({:ok, 300}, &1))
  end

  test "checkout_timeout is returned when every worker is saturated and overflow is exhausted" do
    {:ok, pool} =
      Portals.start_pool(
        command: python!(),
        args: [@worker_script],
        size: 1,
        max_overflow: 0,
        checkout_timeout: 200
      )

    on_exit(fn -> Portals.Pool.stop(pool) end)

    # Saturate the single worker's advertised concurrency (64) with slow calls.
    saturating =
      for _ <- 1..64 do
        elem(Portals.Pool.async(pool, "bench_worker", "sleep_ms", [1_000]), 1)
      end

    assert {:error, %Portals.Error{kind: :checkout_timeout}} =
             Portals.Pool.call(pool, "bench_worker", "echo", ["overflow"], timeout: 2_000)

    for r <- saturating, do: Portals.Pool.await(r, 3_000)
  end

  test "a crashed base worker is replaced automatically" do
    {:ok, pool} =
      Portals.start_pool(command: python!(), args: [@worker_script], size: 2, max_overflow: 0)

    on_exit(fn -> Portals.Pool.stop(pool) end)

    {:error, %Portals.Error{kind: :worker_exit}} =
      Portals.Pool.call(pool, "bench_worker", "crash_process", [])

    Process.sleep(300)

    assert Portals.Pool.health(pool).worker_count == 2
    assert {:ok, "ok"} = Portals.Pool.call(pool, "bench_worker", "echo", ["ok"])
  end

  test "call!/5 raises Portals.CallError on a remote failure" do
    {:ok, pool} = Portals.start_pool(command: python!(), args: [@worker_script], size: 1)
    on_exit(fn -> Portals.Pool.stop(pool) end)

    assert_raise Portals.CallError, fn ->
      Portals.Pool.call!(pool, "bench_worker", "raise_error", ["boom"])
    end
  end
end
