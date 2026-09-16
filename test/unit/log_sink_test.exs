defmodule Portals.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portals.LogSink

  test "a function sink receives every emitted event" do
    {:ok, sink} = LogSink.start_link(name: nil)
    test_pid = self()

    LogSink.attach(:forward, fn event -> send(test_pid, {:logged, event}) end, sink)

    event = %{level: :info, message: "worker started"}
    LogSink.emit(event, sink)

    assert_receive {:logged, ^event}, 1_000
  end

  test "detach stops delivery" do
    {:ok, sink} = LogSink.start_link(name: nil)
    test_pid = self()

    LogSink.attach(:forward, fn event -> send(test_pid, {:logged, event}) end, sink)
    LogSink.detach(:forward, sink)
    LogSink.emit(%{level: :info, message: "should not arrive"}, sink)

    refute_receive {:logged, _}, 200
  end

  test "a file sink appends one line per event" do
    {:ok, sink} = LogSink.start_link(name: nil)

    path =
      Path.join(
        System.tmp_dir!(),
        "portals_log_sink_test_#{:erlang.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(path) end)

    LogSink.attach(:file, {:file, path}, sink)
    LogSink.emit(%{level: :warning, message: "disk almost full"}, sink)
    LogSink.detach(:file, sink)

    assert File.read!(path) =~ "disk almost full"
  end
end
