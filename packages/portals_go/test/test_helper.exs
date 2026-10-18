ExUnit.start()

# Callback targets must already exist as atoms before a worker can name them
# (protocol/v1.md section 5.3); the shared suites call back into this one.
Code.ensure_loaded!(Portals.Fixtures.CallbackTarget)

# Go workers are compiled programs: build the SDK's fixture worker and the
# guide's example once, before any test launches them.
defmodule PortalsGo.TestArtifacts do
  @moduledoc false
  def binary(name), do: Path.join([Mix.Project.build_path(), "portals_go_test", name])

  def build!(name, dir, package) do
    case System.cmd("go", ["build", "-o", binary(name), package], cd: dir, stderr_to_stdout: true) do
      {_, 0} -> binary(name)
      {output, status} -> raise "go build failed (#{status}):\n#{output}"
    end
  end
end

PortalsGo.TestArtifacts.build!(
  "fixture_worker",
  Path.expand("../priv/go", __DIR__),
  "./test/fixtures/worker"
)

PortalsGo.TestArtifacts.build!("guide_worker", Path.expand("guide", __DIR__), ".")
