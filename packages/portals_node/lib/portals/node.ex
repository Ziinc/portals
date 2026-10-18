defmodule Portals.Node do
  @moduledoc """
  Run Node.js workers under Portals.

  This package bundles the dependency-free Node.js worker SDK as the
  `portals-worker` module and puts its parent directory on the worker's
  `NODE_PATH`, so a CommonJS worker script can simply
  `require('portals-worker')` — nothing is installed with `npm`.

      children = [
        {Portals.Pool,
         Portals.Node.worker_opts(
           script: Application.app_dir(:my_app, "priv/node/worker.js"),
           name: MyApp.Node,
           size: 4
         )}
      ]

  See the [Node.js guide](node.html) for a full walkthrough, including ES
  module workers (which do not consult `NODE_PATH`).
  """

  @behaviour Portals.SDK

  @impl true
  def sdk_path, do: Application.app_dir(:portals_node, "priv/node/portals-worker")

  @doc """
  Build `Portals.start_worker/1` / `Portals.start_pool/1` options for a
  Node.js worker script.

  ## Options

    * `:script` (required) — path to the worker entry script, which calls
      `new Worker({...}).run()`.
    * `:node` — the runtime, as a name looked up on `PATH` or a path.
      Defaults to `"node"`.
    * `:node_args` — runtime flags placed before the script, e.g.
      `["--max-old-space-size=512"]`.
    * `:args` — arguments passed to the script. Portals appends the socket
      path after these, as the last argument.
    * `:env` — extra `{name, value}` environment entries; these win over
      the ones set here.

  Every other option is passed through unchanged. The SDK's parent
  directory is prepended to any `NODE_PATH` already set in the BEAM's
  environment.
  """
  @impl true
  def worker_opts(opts) do
    {script, opts} = Keyword.pop!(opts, :script)
    {node, opts} = Keyword.pop(opts, :node, "node")
    {node_args, opts} = Keyword.pop(opts, :node_args, [])
    {args, opts} = Keyword.pop(opts, :args, [])

    Portals.SDK.build_opts(
      sdk_path(),
      Portals.SDK.find_executable!(node),
      node_args ++ [Path.expand(script) | args],
      [Portals.SDK.prepend_search_path("NODE_PATH", Path.dirname(sdk_path()))],
      opts
    )
  end
end
