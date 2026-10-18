defmodule Portals.NodeTest do
  use ExUnit.Case, async: true

  test "the SDK is bundled under priv/" do
    assert File.exists?(Path.join(Portals.Node.sdk_path(), "index.js"))
  end

  test "worker_opts/1 sets PORTALS_SDK_PATH and passes other options through" do
    opts = Portals.Node.worker_opts(script: "worker.js", name: MyApp.Workers, size: 3)

    assert {"PORTALS_SDK_PATH", Portals.Node.sdk_path()} in opts[:env]
    assert opts[:name] == MyApp.Workers
    assert opts[:size] == 3
  end

  test "worker_opts/1 runs the script with the node on PATH and the SDK on NODE_PATH" do
    opts = Portals.Node.worker_opts(script: "worker.js", args: ["--verbose"])

    assert opts[:command] == System.find_executable("node")
    assert opts[:args] == [Path.expand("worker.js"), "--verbose"]
    assert {"NODE_PATH", value} = List.keyfind(opts[:env], "NODE_PATH", 0)
    assert value |> String.split(":") |> hd() == Path.dirname(Portals.Node.sdk_path())
  end

  test "worker_opts/1 places interpreter flags before the script" do
    opts = Portals.Node.worker_opts(script: "worker.js", node_args: ["-flag"])
    assert opts[:args] == ["-flag", Path.expand("worker.js")]
  end

  test "worker_opts/1 rejects an interpreter that does not exist" do
    assert_raise ArgumentError, ~r/does not exist/, fn ->
      Portals.Node.worker_opts(script: "worker.js", node: "./no/such/node")
    end
  end

  test "the caller's :env entries come after the SDK's, so they win" do
    opts = Portals.Node.worker_opts(script: "worker.js", env: [{"PORTALS_SDK_PATH", "/override"}])
    assert List.last(opts[:env]) == {"PORTALS_SDK_PATH", "/override"}
  end

  test "mix portals.sdk_path node prints the SDK path" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Portals.SdkPath.run(["node"])
    assert_received {:mix_shell, :info, [path]}
    assert path == Portals.Node.sdk_path()
  end
end
