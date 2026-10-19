defmodule Mix.Tasks.HelloLive.BuildWorkers do
  @shortdoc "Builds the Java and Go greeter workers into priv/"
  @moduledoc """
  Compiles `priv/java/src` against the `portals.jar` bundled in
  `portals_java`, and `go/` into `priv/bin/greeter_go`. Runs after every
  `mix compile` (see the alias in mix.exs).
  """

  use Mix.Task

  @impl true
  def run(_args) do
    # portals_java is a path dependency here, so its jar is a build artifact;
    # a Hex install ships it prebuilt and this step is a no-op.
    Mix.Task.run("portals_java.jar")

    build_java()
    build_go()
  end

  defp build_java do
    sources = Path.wildcard("priv/java/src/**/*.java")
    out = "priv/java/classes"

    if stale?(sources, Path.join(out, "greeter/RunWorker.class")) do
      File.mkdir_p!(out)
      cmd!("javac", ["--release", "17", "-cp", Portals.Java.sdk_path(), "-d", out | sources])
    end
  end

  defp build_go do
    if stale?(
         Path.wildcard("go/*") ++ [Path.join(Portals.Go.sdk_path(), "worker.go")],
         "priv/bin/greeter_go"
       ) do
      cmd!("go", ["build", "-o", "../priv/bin/greeter_go", "."], cd: "go")
    end
  end

  defp stale?(sources, target) do
    case File.stat(target, time: :posix) do
      {:ok, %{mtime: built}} -> Enum.any?(sources, &(File.stat!(&1, time: :posix).mtime > built))
      {:error, _} -> true
    end
  end

  defp cmd!(executable, args, opts \\ []) do
    case System.cmd(executable, args, [stderr_to_stdout: true] ++ opts) do
      {_, 0} -> :ok
      {output, status} -> Mix.raise("#{executable} failed (#{status}):\n#{output}")
    end
  end
end
