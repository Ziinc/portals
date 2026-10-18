defmodule Portals.Integration.StdioTransportTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    {:ok, conn} =
      Portals.start_worker(
        Portals.Test.PythonWorker.opts("run_worker_stdio.py", transport: :stdio)
      )

    on_exit(fn -> Portals.stop_worker(conn, 500) end)
    {:ok, conn: conn}
  end

  test "the framed stdio fallback transport completes calls end to end", %{conn: conn} do
    assert {:ok, "hello"} = Portals.call(conn, "bench_worker", "echo", ["hello"])
    assert {:ok, 7} = Portals.call(conn, "bench_worker", "add", [3, 4])
  end

  test "malformed input over stdio is rejected without raising", %{conn: conn} do
    {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [2_000])

    state = :sys.get_state(conn)
    send(conn, {state.socket, {:data, <<0xFF, 0xFF, 0xFF, 0xFF>>}})

    assert {:error, %Portals.Error{kind: :protocol}} = Portals.await(request, 3_000)
  end
end
