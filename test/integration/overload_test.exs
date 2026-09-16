defmodule Portals.Integration.OverloadTest do
  @moduledoc """
  Phase 9 overload hardening: flood a small pool with far more concurrent
  calls than it can absorb and assert the pool applies backpressure
  (bounded `:checkout_timeout` errors) rather than crashing or hanging.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  test "flooding a saturated pool yields bounded errors, not crashes or hangs" do
    {:ok, pool} =
      Portals.start_pool(
        Portals.Test.PythonWorker.opts("run_worker.py",
          size: 1,
          max_overflow: 1,
          checkout_timeout: 300
        )
      )

    on_exit(fn -> Portals.Pool.stop(pool) end)

    flood_count = 400

    tasks =
      for _ <- 1..flood_count do
        Task.async(fn ->
          Portals.Pool.call(pool, "bench_worker", "sleep_ms", [50], timeout: 5_000)
        end)
      end

    results = Task.await_many(tasks, 20_000)

    assert length(results) == flood_count

    assert Enum.all?(results, fn
             {:ok, 50} -> true
             {:error, %Portals.Error{}} -> true
             _ -> false
           end)

    assert Enum.any?(results, &match?({:ok, 50}, &1))

    assert Process.alive?(pool)
    assert Portals.Pool.health(pool).worker_count >= 1
    assert {:ok, "still alive"} = Portals.Pool.call(pool, "bench_worker", "echo", ["still alive"])
  end
end
