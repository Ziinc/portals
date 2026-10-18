# portals_java

Java worker SDK for [Portals](https://hexdocs.pm/portals): call Java code
from Elixir in supervised, pooled OS processes.

This package bundles the Java worker SDK under `priv/java/portals.jar` (prebuilt, put first on the classpath) and provides
`Portals.Java`, which builds the launch options for `Portals.start_worker/1` and
`Portals.Pool`. Nothing is installed from a Java package registry: the SDK
comes from Hex, versioned in lockstep with `portals`.

## Installation

```elixir
def deps do
  [
    {:portals_java, "~> 0.1.0"}
  ]
end
```

`portals_java` depends on `portals`, so this one line is enough. You need
JDK 17+ on the machine that runs the workers.

## Usage

```java
// RunWorker.java — compile with: javac -cp "$(mix portals.sdk_path java)" ...
new portals.Worker().register("text_tools", TextTools.class).run(args);
```

```elixir
children = [
    {Portals.Pool,
     Portals.Java.worker_opts(
       main: "com.example.RunWorker",
       classpath: [Application.app_dir(:my_app, "priv/java/classes")],
       name: MyApp.Java,
       size: 2
     )}
]

{:ok, 2} = Portals.Pool.call(MyApp.Java, "text_tools", "word_count", ["hello world"])
```

The [Java guide](https://hexdocs.pm/portals_java/java.html) walks
through setup, callbacks, messaging, streaming, deployment, gotchas and
best practices.

## Development

This package lives in the [Portals monorepo](https://github.com/Ziinc/portals)
under `packages/portals_java`. `mix test` runs the shared conformance and
integration suites against the bundled SDK; see `CONTRIBUTING.md` at the
repository root.

## License

MIT
