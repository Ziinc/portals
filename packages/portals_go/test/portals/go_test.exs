defmodule Portals.GoTest do
  use ExUnit.Case, async: true

  test "the SDK is bundled under priv/" do
    assert File.exists?(Path.join(Portals.Go.sdk_path(), "go.mod"))
  end

  test "worker_opts/1 sets PORTALS_SDK_PATH and passes other options through" do
    opts =
      Portals.Go.worker_opts(
        binary: PortalsGo.TestArtifacts.binary("guide_worker"),
        name: MyApp.Workers,
        size: 3
      )

    assert {"PORTALS_SDK_PATH", Portals.Go.sdk_path()} in opts[:env]
    assert opts[:name] == MyApp.Workers
    assert opts[:size] == 3
  end

  test "worker_opts/1 runs the compiled binary directly" do
    binary = PortalsGo.TestArtifacts.binary("guide_worker")
    opts = Portals.Go.worker_opts(binary: binary, args: ["--verbose"])

    assert opts[:command] == binary
    assert opts[:args] == ["--verbose"]
  end

  test "worker_opts/1 explains a binary that has not been built" do
    assert_raise ArgumentError, ~r/build it with `go build`/, fn ->
      Portals.Go.worker_opts(binary: "_build/no_such_worker")
    end
  end

  test "the caller's :env entries come after the SDK's, so they win" do
    opts =
      Portals.Go.worker_opts(
        binary: PortalsGo.TestArtifacts.binary("guide_worker"),
        env: [{"PORTALS_SDK_PATH", "/override"}]
      )

    assert List.last(opts[:env]) == {"PORTALS_SDK_PATH", "/override"}
  end

  test "mix portals.sdk_path go prints the SDK path" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Portals.SdkPath.run(["go"])
    assert_received {:mix_shell, :info, [path]}
    assert path == Portals.Go.sdk_path()
  end
end
