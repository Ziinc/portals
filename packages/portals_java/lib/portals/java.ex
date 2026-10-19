defmodule Portals.Java do
  @moduledoc """
  Run Java workers under Portals.

  This package bundles the dependency-free Java worker SDK as a prebuilt
  `portals.jar` (compiled for Java 17) and puts it on the worker's
  classpath ahead of your own classes — nothing is fetched from Maven.

  Compile your handlers against the same jar
  (`javac -cp "$(mix portals.sdk_path java)" ...`), then:

      children = [
        {Portals.Pool,
         Portals.Java.worker_opts(
           main: "com.example.RunWorker",
           classpath: [Application.app_dir(:my_app, "priv/java/classes")],
           name: MyApp.Java,
           size: 2
         )}
      ]

  See the [Java guide](java.html) for a full walkthrough.
  """

  @behaviour Portals.SDK

  @doc "Absolute path to the bundled `portals.jar`."
  @impl true
  def sdk_path, do: Application.app_dir(:portals_java, "priv/java/portals.jar")

  @doc """
  Build `Portals.start_worker/1` / `Portals.start_pool/1` options for a Java
  worker.

  ## Options

    * `:main` (required) — the fully qualified class whose `main` runs
      `new Worker()...run(args)`.
    * `:classpath` — your own classpath entries (directories or jars),
      appended after `portals.jar`. Defaults to `[]`.
    * `:java` — the `java` launcher, as a name looked up on `PATH` or a
      path. Defaults to `"java"`.
    * `:java_args` — JVM flags placed before `-cp`, e.g. `["-Xmx512m"]`.
    * `:args` — arguments passed to `main`. Portals appends the socket path
      after these, as the last argument.
    * `:env` — extra `{name, value}` environment entries; these win over
      the ones set here.

  Every other option is passed through unchanged.
  """
  @impl true
  def worker_opts(opts) do
    {main, opts} = Keyword.pop!(opts, :main)
    {classpath, opts} = Keyword.pop(opts, :classpath, [])
    {java, opts} = Keyword.pop(opts, :java, "java")
    {java_args, opts} = Keyword.pop(opts, :java_args, [])
    {args, opts} = Keyword.pop(opts, :args, [])

    jar = sdk_path()

    unless File.regular?(jar) do
      raise ArgumentError,
            "#{jar} is missing; it ships in the Hex package, so this only happens " <>
              "when portals_java is a path dependency: run `mix portals_java.jar` in it"
    end

    cp = Enum.map_join([jar | classpath], ":", &Path.expand/1)

    Portals.SDK.build_opts(
      jar,
      Portals.SDK.find_executable!(java),
      java_args ++ ["-cp", cp, main | args],
      [],
      opts
    )
  end
end
