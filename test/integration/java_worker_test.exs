defmodule Portals.Integration.JavaWorkerTest do
  @moduledoc """
  Phase 7: the bundled Java SDK is held to exactly the same black-box
  expectations as the reference Python SDK (see
  `Portals.Fixtures.WorkerSuite`).

  The worker is launched through `run_worker.sh`, which compiles the SDK
  with plain `javac` on first use. Compiling here as well, while the test
  files load, means no test's handshake timeout ever includes a compile.
  """

  build = Path.expand("../../sdk/java/build.sh", __DIR__)

  case System.cmd("sh", [build], stderr_to_stdout: true) do
    {_, 0} -> :ok
    {output, status} -> raise "sdk/java/build.sh failed (#{status}):\n#{output}"
  end

  use Portals.Fixtures.WorkerSuite,
    runtime: "sh",
    script: "sdk/java/test/fixtures/run_worker.sh"
end
