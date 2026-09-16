defmodule Portals.HealthTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  @worker_script Path.expand("../../sdk/python/tests/fixtures/run_worker.py", __DIR__)

  defp python! do
    System.find_executable("python3") ||
      raise "python3 not available; required for Portals integration tests"
  end

  test "snapshots a single connection" do
    {:ok, conn} = Portals.start_worker(command: python!(), args: [@worker_script])
    on_exit(fn -> Portals.stop_worker(conn, 500) end)

    snapshot = Portals.Health.snapshot(conn)
    assert snapshot.kind == :worker
    assert snapshot.status == :ready
    assert snapshot.in_flight == 0
  end

  test "snapshots a pool with aggregate totals" do
    {:ok, pool} =
      Portals.start_pool(command: python!(), args: [@worker_script], size: 2, max_overflow: 1)

    on_exit(fn -> Portals.Pool.stop(pool) end)

    snapshot = Portals.Health.snapshot(pool)
    assert snapshot.kind == :pool
    assert snapshot.worker_count == 2
    assert snapshot.queue_depth == 0
    assert snapshot.capacity_total > 0
  end
end
