defmodule Portals.SocketDirTest do
  use ExUnit.Case, async: false

  alias Portals.SocketDir

  test "allocates a private 0700 directory and a socket path inside it" do
    {:ok, dir, socket_path} = SocketDir.allocate("test_#{:erlang.unique_integer([:positive])}")

    assert File.dir?(dir)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(dir)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert Path.dirname(socket_path) == dir

    SocketDir.cleanup(dir)
    refute File.exists?(dir)
  end

  test "removes a stale socket file left over from an unclean shutdown" do
    worker_id = "test_#{:erlang.unique_integer([:positive])}"
    {:ok, dir, socket_path} = SocketDir.allocate(worker_id)
    File.write!(socket_path, "stale")
    assert File.exists?(socket_path)

    {:ok, ^dir, ^socket_path} = SocketDir.allocate(worker_id)
    refute File.exists?(socket_path)

    SocketDir.cleanup(dir)
  end
end
