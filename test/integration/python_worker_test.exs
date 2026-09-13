defmodule Portals.Integration.PythonWorkerTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  @worker_script Path.expand("../../sdk/python/tests/fixtures/run_worker.py", __DIR__)

  setup do
    python =
      System.find_executable("python3") || System.find_executable("python") ||
        raise "python3 not available; required for Portals integration tests"

    {:ok, conn} = Portals.start_worker(command: python, args: [@worker_script])
    on_exit(fn -> Portals.stop_worker(conn, 500) end)
    {:ok, conn: conn}
  end

  test "calls an arbitrary module/function and gets the result back", %{conn: conn} do
    assert {:ok, "hello"} = Portals.call(conn, "bench_worker", "echo", ["hello"])
    assert {:ok, 3} = Portals.call(conn, "bench_worker", "add", [1, 2])
  end

  test "call! returns the value directly", %{conn: conn} do
    assert Portals.call!(conn, "bench_worker", "echo", [42]) == 42
  end

  test "call! raises Portals.CallError on a remote exception", %{conn: conn} do
    assert_raise Portals.CallError, fn ->
      Portals.call!(conn, "bench_worker", "raise_error", ["boom"])
    end
  end

  test "a remote exception is reported as a structured %Portals.Error{}", %{conn: conn} do
    assert {:error, %Portals.Error{kind: :remote, message: "boom"} = error} =
             Portals.call(conn, "bench_worker", "raise_error", ["boom"])

    assert error.remote["exception_type"] == "ValueError"
    assert is_list(error.stacktrace)
  end

  test "many concurrent in-flight calls complete out of order", %{conn: conn} do
    requests =
      for i <- 1..64 do
        delay = rem(64 - i, 5) * 2
        {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [delay])
        {i, request}
      end

    results = for {_i, request} <- requests, do: Portals.await(request, 5_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))
  end

  test "every pending caller receives a terminal error after the worker crashes", %{conn: conn} do
    requests =
      for _ <- 1..5 do
        {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [2_000])
        request
      end

    {:ok, _crash_request} = Portals.async(conn, "bench_worker", "crash_process", [])

    for request <- requests do
      assert {:error, %Portals.Error{kind: :worker_exit}} = Portals.await(request, 3_000)
    end
  end

  test "cancel is cooperative, idempotent, and races safely with the terminal response", %{
    conn: conn
  } do
    {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [50])
    Portals.cancel(request)
    Portals.cancel(request)

    assert {:ok, 50} = Portals.await(request, 2_000)
  end

  test "an async caller that exits does not crash the connection", %{conn: conn} do
    parent = self()

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [1_000])
        send(parent, {:started, request.id})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, _request_id}, 1_000
    Process.exit(caller_pid, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :killed}, 1_000

    Process.sleep(100)
    assert Portals.health(conn).status == :ready
    assert {:ok, "still alive"} = Portals.call(conn, "bench_worker", "echo", ["still alive"])
  end

  test "receiving malformed bytes only terminates that connection", %{conn: conn} do
    {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [2_000])

    # Simulate malformed data arriving from the worker's socket, without
    # depending on the (trusted) Python SDK ever producing it itself.
    state = :sys.get_state(conn)
    send(conn, {:tcp, state.socket, <<0xFF, 0xFF, 0xFF, 0xFF>>})

    assert {:error, %Portals.Error{kind: :protocol}} = Portals.await(request, 3_000)
    assert Portals.health(conn).status == :closed
  end
end
