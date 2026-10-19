defmodule Portals.GuidesTest do
  @moduledoc """
  Each language guide (guides/languages/<language>.md) walks through a
  worker whose code lives in packages/portals_<language>/test/guide/, where
  that package's GuideTest runs it end to end. This keeps the code shown in
  the guide identical to the code that is tested.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  for language <- ~w(python ruby javascript php java go) do
    @language language

    test "the #{language} guide shows its tested example code verbatim" do
      guide = File.read!(Path.join([@root, "guides", "languages", "#{@language}.md"]))
      dir = Path.join([@root, "packages", "portals_#{@language}", "test", "guide"])

      # Source files only: go.mod differs on purpose (the tested copy points
      # at the SDK in this repository, the guide's at deps/).
      files =
        for path <- Path.wildcard(Path.join(dir, "**/*.{py,rb,js,php,java,go}")) do
          path
        end

      assert files != []

      for path <- files do
        code = path |> File.read!() |> String.trim_trailing()

        assert String.contains?(guide, code),
               "guides/languages/#{@language}.md does not contain #{Path.relative_to(path, @root)} verbatim"
      end
    end
  end
end
