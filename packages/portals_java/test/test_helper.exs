ExUnit.start()

# Callback targets must already exist as atoms before a worker can name them
# (protocol/v1.md section 5.3); the shared suites call back into this one.
Code.ensure_loaded!(Portals.Fixtures.CallbackTarget)

# portals.jar is a build artifact here (it ships prebuilt in the Hex
# package). Build it, then compile the SDK's fixtures and the guide's
# example against the jar alone, exactly as an application would.
Mix.Task.run("portals_java.jar")

defmodule PortalsJava.TestArtifacts do
  @moduledoc false
  def dir(name), do: Path.join([Mix.Project.build_path(), "portals_java_test", name])

  # Faster JVM startup for the many short-lived test workers.
  def java_args, do: ["-XX:+UseSerialGC", "-XX:TieredStopAtLevel=1", "-Xshare:auto"]

  def compile!(name, sources) do
    out = dir(name)
    File.rm_rf!(out)
    File.mkdir_p!(out)

    args = ["--release", "17", "-encoding", "UTF-8", "-cp", Portals.Java.sdk_path(), "-d", out]

    case System.cmd("javac", args ++ sources, stderr_to_stdout: true) do
      {_, 0} -> out
      {output, status} -> raise "javac failed (#{status}):\n#{output}"
    end
  end
end

PortalsJava.TestArtifacts.compile!(
  "fixtures",
  Path.wildcard(Path.expand("../priv/java/test/fixtures/*.java", __DIR__))
)

PortalsJava.TestArtifacts.compile!(
  "guide",
  Path.wildcard(Path.expand("guide/**/*.java", __DIR__))
)
