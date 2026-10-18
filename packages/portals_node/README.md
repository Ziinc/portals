# portals_node

Node.js worker SDK for [Portals](https://hexdocs.pm/portals): call Node.js code
from Elixir in supervised, pooled OS processes.

This package bundles the Node.js worker SDK under `priv/node/portals-worker` (resolved through `NODE_PATH`) and provides
`Portals.Node`, which builds the launch options for `Portals.start_worker/1` and
`Portals.Pool`. Nothing is installed from a Node.js package registry: the SDK
comes from Hex, versioned in lockstep with `portals`.

## Installation

```elixir
def deps do
  [
    {:portals_node, "~> 0.1.0"}
  ]
end
```

`portals_node` depends on `portals`, so this one line is enough. You need
Node.js 18+ on the machine that runs the workers.

## Usage

```js
// priv/node/worker.js
const { Worker } = require('portals-worker');

new Worker({ modules: { text_tools: require('./textTools') } }).run();
```

```elixir
children = [
    {Portals.Pool,
     Portals.Node.worker_opts(
       script: Application.app_dir(:my_app, "priv/node/worker.js"),
       name: MyApp.Node,
       size: 4
     )}
]

{:ok, 2} = Portals.Pool.call(MyApp.Node, "text_tools", "word_count", ["hello world"])
```

The [Node.js guide](https://hexdocs.pm/portals_node/node.html) walks
through setup, callbacks, messaging, streaming, deployment, gotchas and
best practices.

## Development

This package lives in the [Portals monorepo](https://github.com/Ziinc/portals)
under `packages/portals_node`. `mix test` runs the shared conformance and
integration suites against the bundled SDK; see `CONTRIBUTING.md` at the
repository root.

## License

MIT
