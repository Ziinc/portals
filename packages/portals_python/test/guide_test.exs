defmodule MyApp.Progress do
  @moduledoc false
  # The callback target from the Python guide. The guide logs; this one
  # reports each step to the running test.
  def report(step) do
    send(:portals_guide_test, {:progress, step})
    :ok
  end
end

defmodule PortalsPython.GuideTest do
  @moduledoc """
  Runs the walkthrough from guides/languages/python.md end to end, using the
  exact worker code shown there (test/guide/).
  """

  use ExUnit.Case

  @moduletag :integration

  @guide Path.expand("guide", __DIR__)
  @worker Portals.Python.worker_opts(script: Path.join(@guide, "worker.py"))

  setup do
    Process.register(self(), :portals_guide_test)
    start_supervised!({Portals.Pool, @worker ++ [name: MyApp.Python, size: 2]})
    :ok
  end

  test "unary calls and structured errors" do
    assert {:ok, 2} = Portals.Pool.call(MyApp.Python, "text_tools", "word_count", ["hello world"])
    assert {:ok, 12} = Portals.Pool.call(MyApp.Python, "text_tools", "parse_int", ["12"])

    assert {:error, %Portals.Error{kind: :remote} = error} =
             Portals.Pool.call(MyApp.Python, "text_tools", "parse_int", ["nope"])

    assert error.message =~ "nope"
    assert error.remote["exception_type"] == "ValueError"
  end

  test "callbacks into Elixir" do
    assert {:ok, 3} = Portals.Pool.call(MyApp.Python, "text_tools", "progress", [3])
    assert_received {:progress, 1}
    assert_received {:progress, 2}
    assert_received {:progress, 3}
  end

  test "messages to a PID" do
    assert {:ok, "sent"} = Portals.Pool.call(MyApp.Python, "text_tools", "notify", [self(), "hi"])
    assert_receive {:portals_message, _worker, "HI"}
  end

  test "bidirectional streaming on a dedicated worker" do
    {:ok, conn} = Portals.start_worker(@worker)
    on_exit(fn -> Portals.stop_worker(conn, 500) end)

    {:ok, stream} = Portals.open_stream(conn, "text_tools", "upcase_stream", [])
    :ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
    assert ["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
    assert {:ok, 3} = Portals.Stream.await(stream)
  end
end
