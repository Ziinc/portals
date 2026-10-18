defmodule HelloLive.Languages do
  @moduledoc """
  One Portals pool per language (and per JavaScript runtime), each running
  a `greeter` worker whose `hello/1` function answers with its runtime's
  version. The four JavaScript pools run the same `priv/js/greeter.js`.
  """

  @languages [
    %{id: "python", name: "Python", pool: HelloLive.Python},
    %{id: "ruby", name: "Ruby", pool: HelloLive.Ruby},
    %{id: "node", name: "JavaScript · Node.js", pool: HelloLive.JS.Node},
    %{id: "bun", name: "JavaScript · Bun", pool: HelloLive.JS.Bun},
    %{id: "deno", name: "JavaScript · Deno", pool: HelloLive.JS.Deno},
    %{id: "quickjs", name: "JavaScript · QuickJS", pool: HelloLive.JS.QuickJS},
    %{id: "php", name: "PHP", pool: HelloLive.PHP},
    %{id: "java", name: "Java", pool: HelloLive.Java},
    %{id: "go", name: "Go", pool: HelloLive.Go}
  ]

  def all, do: @languages

  def fetch!(id), do: Enum.find(@languages, &(&1.id == id)) || raise(ArgumentError, id)

  @doc "A `Portals.Pool` child spec for every language."
  def child_specs do
    for language <- @languages do
      opts = worker_opts(language.id) ++ [name: language.pool, size: 1]
      Supervisor.child_spec({Portals.Pool, opts}, id: language.pool)
    end
  end

  @doc "Call `greeter.hello(name)` in `id`'s worker, timing the round trip."
  def hello(id, name) do
    %{pool: pool} = fetch!(id)
    started = System.monotonic_time()
    result = Portals.Pool.call(pool, "greeter", "hello", [name])
    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

    case result do
      {:ok, greeting} -> {:ok, greeting, elapsed}
      {:error, %Portals.Error{message: message}} -> {:error, message, elapsed}
    end
  end

  defp worker_opts("python"), do: Portals.Python.worker_opts(script: priv("python/worker.py"))
  defp worker_opts("ruby"), do: Portals.Ruby.worker_opts(script: priv("ruby/worker.rb"))

  defp worker_opts(js) when js in ~w(node bun deno quickjs) do
    Portals.JavaScript.worker_opts(
      script: priv("js/worker.js"),
      runtime: String.to_existing_atom(js)
    )
  end

  defp worker_opts("php"), do: Portals.PHP.worker_opts(script: priv("php/worker.php"))

  defp worker_opts("java") do
    Portals.Java.worker_opts(main: "greeter.RunWorker", classpath: [priv("java/classes")])
  end

  defp worker_opts("go"), do: Portals.Go.worker_opts(binary: priv("bin/greeter_go"))

  defp priv(path), do: Application.app_dir(:hello_live, Path.join("priv", path))
end
