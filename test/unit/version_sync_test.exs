defmodule Portals.VersionSyncTest do
  @moduledoc """
  Core `portals`, every `portals_<language>` package and the SDK each one
  bundles are released in lockstep, so every version location in the
  monorepo must agree (see scripts/version.exs).
  """

  use ExUnit.Case, async: true

  test "every package and SDK carries the same version as core" do
    script = Path.expand("../../scripts/version.exs", __DIR__)

    {output, status} =
      System.cmd(System.find_executable("elixir"), [script, "check"], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "at #{Mix.Project.config()[:version]}"
  end
end
