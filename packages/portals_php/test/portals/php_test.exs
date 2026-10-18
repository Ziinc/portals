defmodule Portals.PHPTest do
  use ExUnit.Case, async: true

  test "the SDK is bundled under priv/" do
    assert File.exists?(Path.join(Portals.PHP.sdk_path(), "portals.php"))
  end

  test "worker_opts/1 sets PORTALS_SDK_PATH and passes other options through" do
    opts = Portals.PHP.worker_opts(script: "worker.php", name: MyApp.Workers, size: 3)

    assert {"PORTALS_SDK_PATH", Portals.PHP.sdk_path()} in opts[:env]
    assert opts[:name] == MyApp.Workers
    assert opts[:size] == 3
  end

  test "worker_opts/1 loads the SDK with auto_prepend_file before the script" do
    opts = Portals.PHP.worker_opts(script: "worker.php", php_args: ["-n"], args: ["--verbose"])
    prepend = "auto_prepend_file=" <> Path.join(Portals.PHP.sdk_path(), "portals.php")

    assert opts[:command] == System.find_executable("php")
    assert opts[:args] == ["-d", prepend, "-n", Path.expand("worker.php"), "--verbose"]
  end

  test "prepend_sdk: false leaves loading the SDK to the script" do
    opts = Portals.PHP.worker_opts(script: "worker.php", prepend_sdk: false)
    assert opts[:args] == [Path.expand("worker.php")]
  end

  test "the caller's :env entries come after the SDK's, so they win" do
    opts = Portals.PHP.worker_opts(script: "worker.php", env: [{"PORTALS_SDK_PATH", "/override"}])
    assert List.last(opts[:env]) == {"PORTALS_SDK_PATH", "/override"}
  end

  test "mix portals.sdk_path php prints the SDK path" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Portals.SdkPath.run(["php"])
    assert_received {:mix_shell, :info, [path]}
    assert path == Portals.PHP.sdk_path()
  end
end
