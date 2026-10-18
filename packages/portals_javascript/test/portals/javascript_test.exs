defmodule Portals.JavaScriptTest do
  use ExUnit.Case, async: true

  @root Path.dirname(Portals.JavaScript.sdk_path())

  test "the SDK, the Deno resolve hook and the QuickJS host are bundled under priv/" do
    assert File.exists?(Path.join(Portals.JavaScript.sdk_path(), "index.js"))
    assert File.exists?(Path.join(@root, "register.cjs"))
    assert File.exists?(Path.join(@root, "quickjs/host.mjs"))
  end

  test "worker_opts/1 sets PORTALS_SDK_PATH and passes other options through" do
    opts = Portals.JavaScript.worker_opts(script: "worker.js", name: MyApp.Workers, size: 3)

    assert {"PORTALS_SDK_PATH", Portals.JavaScript.sdk_path()} in opts[:env]
    assert opts[:name] == MyApp.Workers
    assert opts[:size] == 3
  end

  test "node (the default) runs the script with the SDK's parent directory on NODE_PATH" do
    opts =
      Portals.JavaScript.worker_opts(
        script: "worker.js",
        runtime_args: ["--flag"],
        args: ["--verbose"]
      )

    assert opts[:command] == System.find_executable("node")
    assert opts[:args] == ["--flag", Path.expand("worker.js"), "--verbose"]
    assert {"NODE_PATH", value} = List.keyfind(opts[:env], "NODE_PATH", 0)
    assert value |> String.split(":") |> hd() == @root
    refute Keyword.has_key?(opts, :transport)
  end

  @tag runtime: :bun
  test "bun runs the script directly, also with NODE_PATH" do
    opts = Portals.JavaScript.worker_opts(script: "worker.js", runtime: :bun)

    assert opts[:command] == System.find_executable("bun")
    assert opts[:args] == [Path.expand("worker.js")]
    assert {"NODE_PATH", _} = List.keyfind(opts[:env], "NODE_PATH", 0)
  end

  @tag runtime: :deno
  test "deno preloads the resolve hook, with CommonJS detection and default permissions" do
    opts =
      Portals.JavaScript.worker_opts(
        script: "worker.js",
        runtime: :deno,
        runtime_args: ["--quiet"]
      )

    assert opts[:command] == System.find_executable("deno")

    assert opts[:args] == [
             "run",
             "--allow-all",
             "--unstable-detect-cjs",
             "--require=" <> Path.join(@root, "register.cjs"),
             "--quiet",
             Path.expand("worker.js")
           ]
  end

  @tag runtime: :deno
  test "deno permissions can be narrowed" do
    opts =
      Portals.JavaScript.worker_opts(
        script: "worker.js",
        runtime: :deno,
        deno_permissions: ["--allow-read", "--allow-env"]
      )

    assert ["run", "--allow-read", "--allow-env" | _] = opts[:args]
  end

  @tag runtime: :deno
  @tag :integration
  test "a deno worker runs with only the permissions the SDK needs" do
    opts =
      Portals.JavaScript.worker_opts(
        script: Path.expand("../guide/worker.js", __DIR__),
        runtime: :deno,
        deno_permissions: ["--allow-read", "--allow-write", "--allow-env", "--allow-net"]
      )

    {:ok, worker} = Portals.start_worker(opts)
    on_exit(fn -> Portals.stop_worker(worker, 500) end)
    assert {:ok, 3} = Portals.call(worker, "text_tools", "word_count", ["a b c"])
  end

  @tag runtime: :quickjs
  test "quickjs runs the script through the bundled host, over stdio" do
    opts = Portals.JavaScript.worker_opts(script: "worker.js", runtime: :quickjs)

    assert opts[:command] == System.find_executable("qjs")
    assert opts[:args] == [Path.join(@root, "quickjs/host.mjs"), Path.expand("worker.js")]
    assert opts[:transport] == :stdio
    assert {"PORTALS_TRANSPORT", "stdio"} in opts[:env]
  end

  test "worker_opts/1 rejects an unknown runtime" do
    assert_raise ArgumentError, ~r/unknown JavaScript runtime :spidermonkey/, fn ->
      Portals.JavaScript.worker_opts(script: "worker.js", runtime: :spidermonkey)
    end
  end

  test "worker_opts/1 rejects an executable that does not exist" do
    assert_raise ArgumentError, ~r/does not exist/, fn ->
      Portals.JavaScript.worker_opts(script: "worker.js", executable: "./no/such/node")
    end
  end

  test "the caller's :env entries come after the SDK's, so they win" do
    opts =
      Portals.JavaScript.worker_opts(
        script: "worker.js",
        env: [{"PORTALS_SDK_PATH", "/override"}]
      )

    assert List.last(opts[:env]) == {"PORTALS_SDK_PATH", "/override"}
  end

  test "mix portals.sdk_path javascript prints the SDK path" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Portals.SdkPath.run(["javascript"])
    assert_received {:mix_shell, :info, [path]}
    assert path == Portals.JavaScript.sdk_path()
  end
end
