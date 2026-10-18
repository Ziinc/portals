defmodule Portals.Go do
  @moduledoc """
  Run Go workers under Portals.

  Go workers are compiled programs, so this package plays two roles:

    * at build time it provides the Go SDK sources (module
      `github.com/Ziinc/portals/sdk/go`) inside `deps/`, which your worker's
      `go.mod` points at with a `replace` directive — the module is never
      fetched from the Go module proxy;
    * at run time `worker_opts/1` launches the binary you built.

  ```
  // go.mod
  require github.com/Ziinc/portals/sdk/go v0.0.0
  replace github.com/Ziinc/portals/sdk/go => ../deps/portals_go/priv/go
  ```

  Run `mix portals.sdk_path go` to print the directory to point at.

      children = [
        {Portals.Pool,
         Portals.Go.worker_opts(
           binary: Application.app_dir(:my_app, "priv/bin/go_worker"),
           name: MyApp.Go,
           size: 2
         )}
      ]

  See the [Go guide](go.html) for a full walkthrough.
  """

  @behaviour Portals.SDK

  @impl true
  def sdk_path, do: Application.app_dir(:portals_go, "priv/go")

  @doc """
  Build `Portals.start_worker/1` / `Portals.start_pool/1` options for a
  compiled Go worker.

  ## Options

    * `:binary` (required) — path to the compiled worker executable.
    * `:args` — arguments passed to the binary. Portals appends the socket
      path after these, as the last argument.
    * `:env` — extra `{name, value}` environment entries, e.g.
      `[{"GOMAXPROCS", "4"}]`.

  Every other option is passed through unchanged.
  """
  @impl true
  def worker_opts(opts) do
    {binary, opts} = Keyword.pop!(opts, :binary)
    {args, opts} = Keyword.pop(opts, :args, [])

    path = Path.expand(binary)

    unless File.regular?(path) do
      raise ArgumentError,
            "Go worker binary #{inspect(path)} does not exist; build it with `go build` first"
    end

    Portals.SDK.build_opts(sdk_path(), path, args, [], opts)
  end
end
