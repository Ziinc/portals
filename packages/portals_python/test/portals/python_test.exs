defmodule Portals.PythonTest do
  use ExUnit.Case, async: true

  test "the SDK is bundled under priv/" do
    assert File.exists?(Path.join(Portals.Python.sdk_path(), "portals/__init__.py"))
  end

  test "worker_opts/1 sets PORTALS_SDK_PATH and passes other options through" do
    opts = Portals.Python.worker_opts(script: "worker.py", name: MyApp.Workers, size: 3)

    assert {"PORTALS_SDK_PATH", Portals.Python.sdk_path()} in opts[:env]
    assert opts[:name] == MyApp.Workers
    assert opts[:size] == 3
  end

  test "worker_opts/1 runs the script with the python3 on PATH and the SDK on PYTHONPATH" do
    opts = Portals.Python.worker_opts(script: "worker.py", args: ["--verbose"])

    assert opts[:command] == System.find_executable("python3")
    assert opts[:args] == [Path.expand("worker.py"), "--verbose"]
    assert {"PYTHONPATH", value} = List.keyfind(opts[:env], "PYTHONPATH", 0)
    assert value |> String.split(":") |> hd() == Portals.Python.sdk_path()
  end

  test "worker_opts/1 places interpreter flags before the script" do
    opts = Portals.Python.worker_opts(script: "worker.py", python_args: ["-flag"])
    assert opts[:args] == ["-flag", Path.expand("worker.py")]
  end

  test "worker_opts/1 rejects an interpreter that does not exist" do
    assert_raise ArgumentError, ~r/does not exist/, fn ->
      Portals.Python.worker_opts(script: "worker.py", python: "./no/such/python3")
    end
  end

  test "the caller's :env entries come after the SDK's, so they win" do
    opts =
      Portals.Python.worker_opts(script: "worker.py", env: [{"PORTALS_SDK_PATH", "/override"}])

    assert List.last(opts[:env]) == {"PORTALS_SDK_PATH", "/override"}
  end

  test "mix portals.sdk_path python prints the SDK path" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Portals.SdkPath.run(["python"])
    assert_received {:mix_shell, :info, [path]}
    assert path == Portals.Python.sdk_path()
  end
end
