defmodule Portals.SDK do
  @moduledoc """
  The contract every `portals_<language>` package implements.

  Core `portals` ships no worker SDKs. Each supported language lives in its
  own Hex package (`portals_python`, `portals_ruby`, `portals_javascript`,
  `portals_php`, `portals_java`, `portals_go`) that bundles its SDK under
  `priv/` and exposes a module implementing this behaviour:

    * `c:sdk_path/0` — where the bundled SDK lives on disk. It is resolved
      through `Application.app_dir/2`, so it is valid under `mix run`, in
      tests and inside a `mix release`.
    * `c:worker_opts/1` — expands language-specific options (a script, a
      main class, a binary) into the generic `:command`/`:args`/`:env`
      options understood by `Portals.start_worker/1` and
      `Portals.start_pool/1`, including whatever puts the SDK on that
      runtime's import path. Every other option passes through untouched.

  Every package also sets `PORTALS_SDK_PATH` in the worker's environment,
  as an escape hatch for scripts that need to locate the SDK themselves.

  All packages are released in lockstep with `portals`, so a worker SDK
  always speaks the protocol version the BEAM expects.
  """

  @doc "Absolute path to the SDK bundled in this package's `priv/` directory."
  @callback sdk_path() :: Path.t()

  @doc "Expand language-specific options into `Portals.start_worker/1` options."
  @callback worker_opts(keyword) :: keyword

  @languages %{
    "python" => {Portals.Python, :portals_python},
    "ruby" => {Portals.Ruby, :portals_ruby},
    "javascript" => {Portals.JavaScript, :portals_javascript},
    "php" => {Portals.PHP, :portals_php},
    "java" => {Portals.Java, :portals_java},
    "go" => {Portals.Go, :portals_go}
  }

  @doc """
  The supported languages and the package that provides each one.

      iex> Portals.SDK.languages()["python"]
      {Portals.Python, :portals_python}
  """
  @spec languages() :: %{String.t() => {module, atom}}
  def languages, do: @languages

  @doc """
  The `Portals.SDK` module for `language`, raising with installation
  instructions when its package is not a dependency of the current project.
  """
  @spec module!(String.t()) :: module
  def module!(language) do
    case Map.fetch(@languages, language) do
      {:ok, {module, app}} ->
        if Code.ensure_loaded?(module) do
          module
        else
          raise ArgumentError,
                "the #{language} SDK is provided by the #{inspect(app)} package; " <>
                  "add {#{inspect(app)}, \"~> #{Application.spec(:portals, :vsn)}\"} to your deps"
        end

      :error ->
        raise ArgumentError,
              "unknown language #{inspect(language)}; supported: " <>
                Enum.join(Enum.sort(Map.keys(@languages)), ", ")
    end
  end

  # -- Helpers shared by the language packages -------------------------------

  @doc false
  # Resolves a runtime executable: a bare name is looked up on `PATH`, a
  # path (anything containing "/") is expanded against the current
  # directory. `Port.open/2` with `:spawn_executable` needs an absolute path.
  @spec find_executable!(String.t()) :: String.t()
  def find_executable!(name) do
    cond do
      String.contains?(name, "/") ->
        path = Path.expand(name)

        if File.regular?(path),
          do: path,
          else: raise(ArgumentError, "worker executable #{inspect(path)} does not exist")

      path = System.find_executable(name) ->
        path

      true ->
        raise ArgumentError, "worker executable #{inspect(name)} was not found on PATH"
    end
  end

  @doc false
  # Prepends `dir` to a PATH-style search variable, preserving whatever the
  # BEAM's own environment already holds (a worker inherits it).
  @spec prepend_search_path(String.t(), Path.t()) :: {String.t(), String.t()}
  def prepend_search_path(var, dir) do
    case System.get_env(var) do
      nil -> {var, dir}
      "" -> {var, dir}
      existing -> {var, dir <> ":" <> existing}
    end
  end

  @doc false
  # Builds the final option list: the SDK's own environment entries come
  # first so a caller-supplied `:env` entry for the same variable wins
  # (`Port.open/2` applies later entries last).
  @spec build_opts(Path.t(), String.t(), [String.t()], [{String.t(), String.t()}], keyword) ::
          keyword
  def build_opts(sdk_path, command, args, sdk_env, opts) do
    {user_env, opts} = Keyword.pop(opts, :env, [])

    [
      command: command,
      args: args,
      env: [{"PORTALS_SDK_PATH", sdk_path} | sdk_env] ++ user_env
    ] ++ opts
  end
end
