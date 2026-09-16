defmodule Portals.Integration.OverloadTest do
  @moduledoc """
  Phase 9 overload hardening: flood a small pool with far more concurrent
  calls than it can absorb and assert the pool applies backpressure
  (bounded `:checkout_timeout` errors) rather than crashing or hanging.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  @worker_script Path.expand("../../sdk/python/tests/fixtures/run_worker.py", __DIR__)

  defp python! do
    System.find_executable("python3") ||
      raise "python3 not available; required for Portals integration tests"
  end

  test "flooding a saturated pool yields bounded errors, not crashes or hangs" do
    {:ok, pool} =
      Portals.start_pool(
        command: python!(),
        args: [@worker_script],
        size: 1,
        max_overflow: 1,
        checkout_timeout: 300
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
