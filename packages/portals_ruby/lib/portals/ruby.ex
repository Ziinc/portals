defmodule Portals.Ruby do
  @moduledoc """
  Run Ruby workers under Portals.

  This package bundles the dependency-free Ruby worker SDK and puts it on
  the worker's `RUBYLIB`, so a worker script can simply `require 'portals'`
  — no gem is installed.

      children = [
        {Portals.Pool,
         Portals.Ruby.worker_opts(
           script: Application.app_dir(:my_app, "priv/ruby/worker.rb"),
           name: MyApp.Ruby,
           size: 4
         )}
      ]

  See the [Ruby guide](ruby.html) for a full walkthrough.
  """

  @behaviour Portals.SDK

  @impl true
  def sdk_path, do: Application.app_dir(:portals_ruby, "priv/ruby/lib")

  @doc """
  Build `Portals.start_worker/1` / `Portals.start_pool/1` options for a
  Ruby worker script.

  ## Options

    * `:script` (required) — path to the worker entry script, which calls
      `Portals::Worker.new(...).run`.
    * `:ruby` — the interpreter, as a name looked up on `PATH` or a path.
      Defaults to `"ruby"`.
    * `:ruby_args` — interpreter flags placed before the script, e.g.
      `["-W0"]`.
    * `:args` — arguments passed to the script. Portals appends the socket
      path after these, as the last argument.
    * `:env` — extra `{name, value}` environment entries; these win over
      the ones set here.

  Every other option is passed through unchanged. The SDK directory is
  prepended to any `RUBYLIB` already set in the BEAM's environment.
  """
  @impl true
  def worker_opts(opts) do
    {script, opts} = Keyword.pop!(opts, :script)
    {ruby, opts} = Keyword.pop(opts, :ruby, "ruby")
    {ruby_args, opts} = Keyword.pop(opts, :ruby_args, [])
    {args, opts} = Keyword.pop(opts, :args, [])

    Portals.SDK.build_opts(
      sdk_path(),
      Portals.SDK.find_executable!(ruby),
      ruby_args ++ [Path.expand(script) | args],
      [Portals.SDK.prepend_search_path("RUBYLIB", sdk_path())],
      opts
    )
  end
end
