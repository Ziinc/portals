defmodule Portals.JavaScript do
  @moduledoc """
  Run JavaScript workers under Portals, on Node.js, Bun, Deno or QuickJS.

  This package bundles one dependency-free JavaScript worker SDK (the
  `portals-worker` module) and makes `require('portals-worker')` resolve to
  it on every runtime, so the same CommonJS worker script runs on all four.
  Nothing is installed with `npm`.

      children = [
        {Portals.Pool,
         Portals.JavaScript.worker_opts(
           script: Application.app_dir(:my_app, "priv/js/worker.js"),
           runtime: :bun,
           name: MyApp.JS,
           size: 4
         )}
      ]

  | `:runtime` | Executable | How the SDK is found | Transport |
  |---|---|---|---|
  | `:node` (default) | `node` | `NODE_PATH` | Unix socket |
  | `:bun` | `bun` | `NODE_PATH` | Unix socket |
  | `:deno` | `deno run` | a preloaded resolve hook (`--require`), with `--unstable-detect-cjs` | Unix socket |
  | `:quickjs` | `qjs` | the bundled QuickJS host, which provides the Node APIs the SDK needs | framed stdio |

  See the [JavaScript guide](javascript.html) for a full walkthrough and
  each runtime's trade-offs.
  """

  @behaviour Portals.SDK

  @runtimes [:node, :bun, :deno, :quickjs]
  @executables %{node: "node", bun: "bun", deno: "deno", quickjs: "qjs"}

  @doc "The supported runtimes."
  @spec runtimes() :: [atom]
  def runtimes, do: @runtimes

  @doc "Absolute path to the bundled `portals-worker` SDK."
  @impl true
  def sdk_path, do: Application.app_dir(:portals_javascript, "priv/javascript/portals-worker")

  @doc """
  Build `Portals.start_worker/1` / `Portals.start_pool/1` options for a
  JavaScript worker script.

  ## Options

    * `:script` (required) — path to the worker entry script, which calls
      `new Worker({...}).run()`.
    * `:runtime` — `:node` (default), `:bun`, `:deno` or `:quickjs`.
    * `:executable` — the runtime's binary, as a name looked up on `PATH`
      or a path. Defaults to `node`, `bun`, `deno` or `qjs`.
    * `:runtime_args` — runtime flags placed before the script, e.g.
      `["--max-old-space-size=512"]` for Node.js.
    * `:deno_permissions` — Deno permission flags. Defaults to
      `["--allow-all"]`; the SDK itself needs `--allow-read`,
      `--allow-write`, `--allow-env` and `--allow-net` (Deno counts
      connecting to the Unix socket as network access).
    * `:args` — arguments passed to the script. Portals appends the socket
      path after these, as the last argument.
    * `:env` — extra `{name, value}` environment entries; these win over
      the ones set here.

  Every other option is passed through unchanged. For `:quickjs` the
  worker always uses the framed stdio transport (`transport: :stdio`),
  because QuickJS has no socket API.
  """
  @impl true
  def worker_opts(opts) do
    {script, opts} = Keyword.pop!(opts, :script)
    {runtime, opts} = Keyword.pop(opts, :runtime, :node)
    {executable, opts} = Keyword.pop(opts, :executable)
    {runtime_args, opts} = Keyword.pop(opts, :runtime_args, [])
    {deno_permissions, opts} = Keyword.pop(opts, :deno_permissions, ["--allow-all"])
    {args, opts} = Keyword.pop(opts, :args, [])

    unless runtime in @runtimes do
      raise ArgumentError,
            "unknown JavaScript runtime #{inspect(runtime)}; expected one of #{inspect(@runtimes)}"
    end

    command = Portals.SDK.find_executable!(executable || Map.fetch!(@executables, runtime))
    script = Path.expand(script)
    root = Path.dirname(sdk_path())

    {launch_args, sdk_env, opts} =
      case runtime do
        runtime when runtime in [:node, :bun] ->
          {runtime_args ++ [script], [Portals.SDK.prepend_search_path("NODE_PATH", root)], opts}

        :deno ->
          register = "--require=" <> Path.join(root, "register.cjs")

          {["run" | deno_permissions] ++
             ["--unstable-detect-cjs", register | runtime_args] ++ [script], [], opts}

        :quickjs ->
          host = Path.join(root, "quickjs/host.mjs")

          {runtime_args ++ [host, script], [{"PORTALS_TRANSPORT", "stdio"}],
           Keyword.put(opts, :transport, :stdio)}
      end

    Portals.SDK.build_opts(sdk_path(), command, launch_args ++ args, sdk_env, opts)
  end
end
