# Every place a release version lives. All of them move together: core
# `portals`, each `portals_<language>` package and the SDK it bundles are
# released in lockstep.
#
#     elixir scripts/version.exs check        # exit 1 if any location drifts
#     elixir scripts/version.exs bump 0.2.0   # rewrite every location
#
# test/unit/version_sync_test.exs runs `check` as part of `mix test`.

defmodule Portals.Release.Version do
  @root Path.expand("..", __DIR__)

  # {path, regex whose first capture is the version}
  @locations [
    {"mix.exs", ~r/@version "([^"]+)"/},
    {"packages/portals_python/mix.exs", ~r/@version "([^"]+)"/},
    {"packages/portals_python/priv/python/portals/__init__.py", ~r/__version__ = "([^"]+)"/},
    {"packages/portals_ruby/mix.exs", ~r/@version "([^"]+)"/},
    {"packages/portals_ruby/priv/ruby/lib/portals.rb", ~r/VERSION = '([^']+)'/},
    {"packages/portals_javascript/mix.exs", ~r/@version "([^"]+)"/},
    {"packages/portals_javascript/priv/javascript/portals-worker/index.js", ~r/VERSION: '([^']+)'/},
    {"packages/portals_javascript/priv/javascript/portals-worker/package.json", ~r/"version": "([^"]+)"/},
    {"packages/portals_php/mix.exs", ~r/@version "([^"]+)"/},
    {"packages/portals_php/priv/php/src/portals.php", ~r/const VERSION = '([^']+)'/},
    {"packages/portals_php/priv/php/composer.json", ~r/"version": "([^"]+)"/},
    {"packages/portals_java/mix.exs", ~r/@version "([^"]+)"/},
    {"packages/portals_java/priv/java/src/portals/Portals.java", ~r/String VERSION = "([^"]+)"/},
    {"packages/portals_go/mix.exs", ~r/@version "([^"]+)"/},
    {"packages/portals_go/priv/go/protocol.go", ~r/const Version = "([^"]+)"/}
  ]

  def locations, do: @locations

  def current do
    for {path, regex} <- @locations do
      contents = File.read!(Path.join(@root, path))

      case Regex.run(regex, contents) do
        [_, version] -> {path, version}
        nil -> raise "no version found in #{path} (pattern #{inspect(regex)})"
      end
    end
  end

  def check do
    versions = current()

    case versions |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [version] ->
        IO.puts("All #{length(versions)} version locations are at #{version}")

      _ ->
        IO.puts(:stderr, "Version locations disagree:")
        for {path, v} <- versions, do: IO.puts(:stderr, "  #{v}\t#{path}")
        System.halt(1)
    end
  end

  def bump(version) do
    unless Version.parse(version) == :error do
      for {path, regex} <- @locations do
        full = Path.join(@root, path)

        updated =
          Regex.replace(regex, File.read!(full), fn whole, old ->
            String.replace(whole, old, version)
          end)

        File.write!(full, updated)
      end

      check()
    else
      IO.puts(:stderr, "#{inspect(version)} is not a valid semantic version")
      System.halt(1)
    end
  end

  def main(["check"]), do: check()
  def main(["bump", version]), do: bump(version)

  def main(_) do
    IO.puts(:stderr, "usage: elixir scripts/version.exs check | bump X.Y.Z")
    System.halt(1)
  end
end

Portals.Release.Version.main(System.argv())
