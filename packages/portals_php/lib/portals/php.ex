defmodule Portals.PHP do
  @moduledoc """
  Run PHP workers under Portals.

  This package bundles the dependency-free PHP worker SDK and loads it into
  the worker with PHP's `auto_prepend_file` setting, so a worker script can
  use `Portals\\Worker` straight away — no `require` and no Composer
  package.

      children = [
        {Portals.Pool,
         Portals.PHP.worker_opts(
           script: Application.app_dir(:my_app, "priv/php/worker.php"),
           name: MyApp.PHP,
           size: 4
         )}
      ]

  See the [PHP guide](php.html) for a full walkthrough.
  """

  @behaviour Portals.SDK

  @impl true
  def sdk_path, do: Application.app_dir(:portals_php, "priv/php/src")

  @doc """
  Build `Portals.start_worker/1` / `Portals.start_pool/1` options for a PHP
  worker script.

  ## Options

    * `:script` (required) — path to the worker entry script, which calls
      `(new Portals\\Worker(...))->run()`.
    * `:php` — the CLI binary, as a name looked up on `PATH` or a path.
      Defaults to `"php"`.
    * `:php_args` — interpreter flags placed before the script, e.g.
      `["-d", "memory_limit=512M"]`.
    * `:prepend_sdk` — load the SDK through `auto_prepend_file`. Defaults
      to `true`. Set it to `false` if your `php.ini` already uses
      `auto_prepend_file`, and `require_once` the SDK yourself from
      `getenv('PORTALS_SDK_PATH') . '/portals.php'`.
    * `:args` — arguments passed to the script. Portals appends the socket
      path after these, as the last argument.
    * `:env` — extra `{name, value}` environment entries; these win over
      the ones set here.

  Every other option is passed through unchanged.
  """
  @impl true
  def worker_opts(opts) do
    {script, opts} = Keyword.pop!(opts, :script)
    {php, opts} = Keyword.pop(opts, :php, "php")
    {php_args, opts} = Keyword.pop(opts, :php_args, [])
    {prepend?, opts} = Keyword.pop(opts, :prepend_sdk, true)
    {args, opts} = Keyword.pop(opts, :args, [])

    prepend_args =
      if prepend?,
        do: ["-d", "auto_prepend_file=" <> Path.join(sdk_path(), "portals.php")],
        else: []

    Portals.SDK.build_opts(
      sdk_path(),
      Portals.SDK.find_executable!(php),
      prepend_args ++ php_args ++ [Path.expand(script) | args],
      [],
      opts
    )
  end
end
