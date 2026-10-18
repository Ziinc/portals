defmodule Mix.Tasks.PortalsJava.Jar do
  @shortdoc "Builds priv/java/portals.jar from the Java SDK sources"
  @moduledoc """
  Compiles the Java SDK sources in `priv/java/src` with `javac --release 17`
  and packages them as `priv/java/portals.jar`.

  The jar ships prebuilt inside the Hex package (publishing runs this task
  first), so applications never need it. It exists for working on
  `portals_java` itself, where the jar is a build artifact.

      mix portals_java.jar
  """

  use Mix.Task

  @impl true
  def run(_args) do
    root = Path.expand("../../../priv/java", __DIR__)
    jar = Path.join(root, "portals.jar")
    classes = Path.join(root, "build/jar-classes")

    sources = Path.wildcard(Path.join(root, "src/**/*.java"))

    if up_to_date?(jar, sources) do
      Mix.shell().info("#{Path.relative_to_cwd(jar)} is up to date")
    else
      File.rm_rf!(classes)
      File.mkdir_p!(classes)

      cmd!("javac", ["--release", "17", "-encoding", "UTF-8", "-d", classes | sources])
      cmd!("jar", ["--create", "--file", jar, "-C", classes, "."])
      Mix.shell().info("Built #{Path.relative_to_cwd(jar)}")
    end
  end

  defp up_to_date?(jar, sources) do
    case File.stat(jar, time: :posix) do
      {:ok, %{mtime: built}} ->
        Enum.all?(sources, fn source -> File.stat!(source, time: :posix).mtime <= built end)

      {:error, _} ->
        false
    end
  end

  defp cmd!(executable, args) do
    path = System.find_executable(executable) || Mix.raise("#{executable} not found on PATH")

    case System.cmd(path, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> Mix.raise("#{executable} failed (#{status}):\n#{output}")
    end
  end
end
