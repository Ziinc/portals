# portals_go

Go worker SDK for [Portals](https://hexdocs.pm/portals): call Go code
from Elixir in supervised, pooled OS processes.

This package bundles the Go worker SDK under `priv/go` (Go module sources for your `replace` directive) and provides
`Portals.Go`, which builds the launch options for `Portals.start_worker/1` and
`Portals.Pool`. Nothing is installed from a Go package registry: the SDK
comes from Hex, versioned in lockstep with `portals`.

## Installation

```elixir
def deps do
  [
    {:portals_go, "~> 0.1.0"}
  ]
end
```

`portals_go` depends on `portals`, so this one line is enough. You need
Go 1.21+ on the machine that runs the workers.

## Usage

```
// go.mod — the SDK is resolved from deps/, never from the Go proxy
require github.com/Ziinc/portals/sdk/go v0.0.0
replace github.com/Ziinc/portals/sdk/go => ../deps/portals_go/priv/go
```

```elixir
children = [
    {Portals.Pool,
     Portals.Go.worker_opts(
       binary: Application.app_dir(:my_app, "priv/bin/text_worker"),
       name: MyApp.Go,
       size: 2
     )}
]

{:ok, 2} = Portals.Pool.call(MyApp.Go, "text_tools", "word_count", ["hello world"])
```

The [Go guide](https://hexdocs.pm/portals_go/go.html) walks
through setup, callbacks, messaging, streaming, deployment, gotchas and
best practices.

## Development

This package lives in the [Portals monorepo](https://github.com/Ziinc/portals)
under `packages/portals_go`. `mix test` runs the shared conformance and
integration suites against the bundled SDK; see `CONTRIBUTING.md` at the
repository root.

## License

MIT
