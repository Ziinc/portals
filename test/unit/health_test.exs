defmodule Portals.HealthTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  test "snapshots a single connection" do
    {:ok, conn} = Portals.start_worker(Portals.Test.PythonWorker.opts("run_worker.py"))
    on_exit(fn -> Portals.stop_worker(conn, 500) end)

    snapshot = Portals.Health.snapshot(conn)
    assert snapshot.kind == :worker
    assert snapshot.status == :ready
    assert snapshot.in_flight == 0
  end

  test "snapshots a pool with aggregate totals" do
    {:ok, pool} =
      Portals.start_pool(
        Portals.Test.PythonWorker.opts("run_worker.py", size: 2, max_overflow: 1)
      )

    on_exit(fn -> Portals.Pool.stop(pool) end)

    snapshot = Portals.Health.snapshot(pool)
    assert snapshot.kind == :pool
    assert snapshot.worker_count == 2
    assert snapshot.queue_depth == 0
    assert snapshot.capacity_total > 0
  end
end
