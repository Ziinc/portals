defmodule Portals.JavaTest do
  use ExUnit.Case, async: true

  test "the SDK is bundled under priv/" do
    assert File.exists?(Portals.Java.sdk_path())
  end

  test "worker_opts/1 sets PORTALS_SDK_PATH and passes other options through" do
    opts = Portals.Java.worker_opts(main: "com.example.RunWorker", name: MyApp.Workers, size: 3)

    assert {"PORTALS_SDK_PATH", Portals.Java.sdk_path()} in opts[:env]
    assert opts[:name] == MyApp.Workers
    assert opts[:size] == 3
  end

  test "worker_opts/1 puts portals.jar first on the classpath, then the main class" do
    opts =
      Portals.Java.worker_opts(
        main: "com.example.RunWorker",
        classpath: ["classes", "lib/dep.jar"],
        java_args: ["-Xmx64m"],
        args: ["--verbose"]
      )

    classpath =
      Enum.join(
        [Portals.Java.sdk_path(), Path.expand("classes"), Path.expand("lib/dep.jar")],
        ":"
      )

    assert opts[:command] == System.find_executable("java")
    assert opts[:args] == ["-Xmx64m", "-cp", classpath, "com.example.RunWorker", "--verbose"]
  end

  test "the caller's :env entries come after the SDK's, so they win" do
    opts =
      Portals.Java.worker_opts(
        main: "com.example.RunWorker",
        env: [{"PORTALS_SDK_PATH", "/override"}]
      )

    assert List.last(opts[:env]) == {"PORTALS_SDK_PATH", "/override"}
  end

  test "mix portals.sdk_path java prints the SDK path" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Portals.SdkPath.run(["java"])
    assert_received {:mix_shell, :info, [path]}
    assert path == Portals.Java.sdk_path()
  end
end
