defmodule Portals.RubyTest do
  use ExUnit.Case, async: true

  test "the SDK is bundled under priv/" do
    assert File.exists?(Path.join(Portals.Ruby.sdk_path(), "portals.rb"))
  end

  test "worker_opts/1 sets PORTALS_SDK_PATH and passes other options through" do
    opts = Portals.Ruby.worker_opts(script: "worker.rb", name: MyApp.Workers, size: 3)

    assert {"PORTALS_SDK_PATH", Portals.Ruby.sdk_path()} in opts[:env]
    assert opts[:name] == MyApp.Workers
    assert opts[:size] == 3
  end

  test "worker_opts/1 runs the script with the ruby on PATH and the SDK on RUBYLIB" do
    opts = Portals.Ruby.worker_opts(script: "worker.rb", args: ["--verbose"])

    assert opts[:command] == System.find_executable("ruby")
    assert opts[:args] == [Path.expand("worker.rb"), "--verbose"]
    assert {"RUBYLIB", value} = List.keyfind(opts[:env], "RUBYLIB", 0)
    assert value |> String.split(":") |> hd() == Portals.Ruby.sdk_path()
  end

  test "worker_opts/1 places interpreter flags before the script" do
    opts = Portals.Ruby.worker_opts(script: "worker.rb", ruby_args: ["-flag"])
    assert opts[:args] == ["-flag", Path.expand("worker.rb")]
  end

  test "worker_opts/1 rejects an interpreter that does not exist" do
    assert_raise ArgumentError, ~r/does not exist/, fn ->
      Portals.Ruby.worker_opts(script: "worker.rb", ruby: "./no/such/ruby")
    end
  end

  test "the caller's :env entries come after the SDK's, so they win" do
    opts = Portals.Ruby.worker_opts(script: "worker.rb", env: [{"PORTALS_SDK_PATH", "/override"}])
    assert List.last(opts[:env]) == {"PORTALS_SDK_PATH", "/override"}
  end

  test "mix portals.sdk_path ruby prints the SDK path" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Portals.SdkPath.run(["ruby"])
    assert_received {:mix_shell, :info, [path]}
    assert path == Portals.Ruby.sdk_path()
  end
end
