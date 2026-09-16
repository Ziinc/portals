defmodule Portals.Health do
  @moduledoc """
  Point-in-time health snapshots for a `Portals.Connection` or
  `Portals.Pool` (Phase 8).

  Unlike `:telemetry` events (`Portals.Telemetry`), which are a stream of
  point events, `snapshot/1` gives a single map describing current state:
  worker counts, in-flight requests, and queue depth. Suitable for polling
  from a `/health` HTTP endpoint, a periodic Logger report, or an
  operations dashboard.
  """

  @doc """
  Return a health snapshot for a single connection or a whole pool.

  For a `Portals.Connection`, delegates to `Portals.Connection.health/1`
  and normalizes the shape. For a `Portals.Pool`, delegates to
  `Portals.Pool.health/1` and adds aggregate totals.
  """
  @spec snapshot(GenServer.server()) :: map
  def snapshot(server) do
    raw = GenServer.call(server, :health)
    normalize(raw)
  end

  defp normalize(%{workers: workers} = pool_health) do
    in_flight_total = workers |> Map.values() |> Enum.map(& &1.in_flight) |> Enum.sum()

    capacity_total = workers |> Map.values() |> Enum.map(& &1.max_concurrency) |> Enum.sum()

    %{
      kind: :pool,
      worker_count: pool_health.worker_count,
      size: pool_health.size,
      max_overflow: pool_health.max_overflow,
      queue_depth: pool_health.waiting,
      in_flight_total: in_flight_total,
      capacity_total: capacity_total,
      workers: workers
    }
  end

  defp normalize(%{status: _} = conn_health) do
    %{
      kind: :worker,
      status: conn_health.status,
      in_flight: conn_health.in_flight,
      in_flight_callbacks: conn_health.in_flight_callbacks,
      open_streams: conn_health.open_streams,
      max_streams: conn_health.max_streams,
      worker_info: conn_health.worker_info
    }
  end
end
