defmodule Portals.Python do
  @moduledoc """
  Run Python workers under Portals.

  This package bundles the dependency-free Python worker SDK (the `portals`
  Python package) and puts it on the worker's `PYTHONPATH`, so a worker
  script can simply `from portals import Worker` — nothing is installed with
  `pip`.

      children = [
        {Portals.Pool,
         Portals.Python.worker_opts(
           script: Application.app_dir(:my_app, "priv/python/worker.py"),
           name: MyApp.Python,
           size: 4
         )}
      ]

  See the [Python guide](python.html) for a full walkthrough.
  """

  @behaviour Portals.SDK

  @impl true
  def sdk_path, do: Application.app_dir(:portals_python, "priv/python")

  @doc """
  Build `Portals.start_worker/1` / `Portals.start_pool/1` options for a
  Python worker script.

  ## Options

    * `:script` (required) — path to the worker entry script, which calls
      `portals.Worker(...).run()`.
    * `:python` — the interpreter, as a name looked up on `PATH` or a path
      such as `".venv/bin/python"`. Defaults to `"python3"`.
    * `:python_args` — interpreter flags placed before the script, e.g.
      `["-X", "dev"]`.
    * `:args` — arguments passed to the script. Portals appends the socket
      path after these, as the last argument.
    * `:env` — extra `{name, value}` environment entries; these win over
      the ones set here.

  Every other option (`:name`, `:size`, `:max_overflow`, `:limits`, ...) is
  passed through unchanged.

  The SDK directory is prepended to any `PYTHONPATH` already set in the
  BEAM's environment.
  """
  @impl true
  def worker_opts(opts) do
    {script, opts} = Keyword.pop!(opts, :script)
    {python, opts} = Keyword.pop(opts, :python, "python3")
    {python_args, opts} = Keyword.pop(opts, :python_args, [])
    {args, opts} = Keyword.pop(opts, :args, [])

    Portals.SDK.build_opts(
      sdk_path(),
      Portals.SDK.find_executable!(python),
      python_args ++ [Path.expand(script) | args],
      [Portals.SDK.prepend_search_path("PYTHONPATH", sdk_path())],
      opts
    )
  end
end
