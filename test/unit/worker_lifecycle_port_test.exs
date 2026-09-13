defmodule Portals.WorkerLifecycle.PortTest do
  use ExUnit.Case, async: true

  alias Portals.WorkerLifecycle.Port, as: Lifecycle

  test "launches a direct worker, exposes its OS pid, and detects normal exit" do
    {:ok, port} = Lifecycle.launch(command: "sh", args: ["-c", "sleep 0.2; exit 0"])
    assert {:ok, os_pid} = Lifecycle.os_pid(port)
    assert is_integer(os_pid)

    assert_receive {^port, {:exit_status, 0}}, 2_000
  end

  test "force-kills a worker that ignores graceful shutdown after the deadline" do
    {:ok, port} = Lifecycle.launch(command: "sh", args: ["-c", "trap '' TERM; sleep 30"])
    {:ok, os_pid} = Lifecycle.os_pid(port)

    :ok = Lifecycle.terminate(port, 200)

    # Give the OS a moment to reap the killed process, then confirm it is gone.
    Process.sleep(200)

    assert {_output, exit_code} =
             System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert exit_code != 0
  end

  test "returns an error for a command that cannot be resolved to an executable" do
    assert {:error, {:executable_not_found, _}} =
             Lifecycle.launch(command: "definitely_not_a_real_command_xyz")
  end
end
