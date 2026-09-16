defmodule Portals.Integration.CallbacksAndMessagingTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  @worker_script Path.expand("../../sdk/python/tests/fixtures/run_worker.py", __DIR__)

  setup do
    python =
      System.find_executable("python3") ||
        raise "python3 not available; required for Portals integration tests"

    {:ok, conn} = Portals.start_worker(command: python, args: [@worker_script])
    on_exit(fn -> Portals.stop_worker(conn, 500) end)
    {:ok, conn: conn}
  end

  test "a Python handler can call back into the BEAM and get a result", %{conn: conn} do
    assert {:ok, 84} = Portals.call(conn, "bench_worker", "double_via_callback", [42])
  end

  test "a failing BEAM callback target is reported back to Python as a remote error", %{
    conn: conn
  } do
    assert {:error, %Portals.Error{kind: :remote} = error} =
             Portals.call(conn, "bench_worker", "raise_callback_error", [])

    assert error.message =~ "callback target exploded"
  end

  test "trusted PID messaging: the worker can message the calling process directly", %{
    conn: conn
  } do
    {:ok, "sent"} =
      Portals.call(conn, "bench_worker", "message_to_caller", [self(), %{"progress" => 0.5}])

    assert_receive {:portals_message, ^conn, %{"progress" => 0.5}}, 2_000
  end

  test "an unknown callback target is rejected without crashing the connection", %{conn: conn} do
    # bench_worker.double_via_callback always targets a real Elixir module;
    # here we drive an ad hoc callback frame for one that doesn't exist.
    state = :sys.get_state(conn)

    frame = [Portals.Protocol.frame_tag(:callback), 999_999, "NoSuchModule", "nope", []]
    {:ok, bytes} = Portals.Codec.MessagePack.encode(frame, state.limits)
    send(conn, {:tcp, state.socket, bytes})

    Process.sleep(100)
    assert Portals.health(conn).status == :ready
  end

  test "an in-flight call still resolves normally while unrelated callbacks are handled", %{
    conn: conn
  } do
    {:ok, sleeper} = Portals.async(conn, "bench_worker", "sleep_ms", [200])
    {:ok, 20} = Portals.call(conn, "bench_worker", "double_via_callback", [10])
    assert {:ok, 200} = Portals.await(sleeper, 2_000)
  end
end
