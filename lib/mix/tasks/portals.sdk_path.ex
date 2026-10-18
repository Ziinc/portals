defmodule Mix.Tasks.Portals.SdkPath do
  @shortdoc "Prints where a language package's bundled worker SDK lives"
  @moduledoc """
  Prints the absolute path of the worker SDK bundled with a language
  package, for configuring editors, type checkers, `go.mod` `replace`
  directives or `javac -cp`:

      $ mix portals.sdk_path python
      /app/_build/dev/lib/portals_python/priv/python

  The path is the last line of output; when dependencies still need
  compiling, Mix prints its own progress first, so scripts should take the
  last line: `$(mix portals.sdk_path java | tail -n 1)`.

  The language's package (`portals_python`, ...) must be a dependency of
  the current project. Supported languages: #{Enum.join(Enum.sort(Map.keys(Portals.SDK.languages())), ", ")}.
  """

  use Mix.Task

  @impl true
  def run([language]) do
    # Print nothing but the path, so `$(mix portals.sdk_path go)` works in
    # shell scripts even when dependencies still need compiling.
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      Mix.Task.run("loadpaths")
      Mix.Task.run("compile")
    after
      Mix.shell(shell)
    end

    module =
      try do
        Portals.SDK.module!(language)
      rescue
        e in ArgumentError -> Mix.raise(Exception.message(e))
      end

    Mix.shell().info(module.sdk_path())
  end

  def run(_args) do
    Mix.raise("usage: mix portals.sdk_path <language>")
  end
end
