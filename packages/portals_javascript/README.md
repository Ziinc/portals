# portals_javascript

JavaScript worker SDK for [Portals](https://hexdocs.pm/portals): call
JavaScript from Elixir in supervised, pooled OS processes, on **Node.js,
Bun, Deno or QuickJS**.

This package bundles one dependency-free JavaScript SDK (the
`portals-worker` module, under `priv/javascript`) and provides
`Portals.JavaScript`, which builds the launch options for
`Portals.start_worker/1` and `Portals.Pool` and makes
`require('portals-worker')` resolve to the SDK on every runtime. Nothing is
installed from npm: the SDK comes from Hex, versioned in lockstep with
`portals`.

## Installation

```elixir
def deps do
  [
    {:portals_javascript, "~> 0.1.0"}
  ]
end
```

`portals_javascript` depends on `portals`, so this one line is enough. You
need one of the runtimes on the machine that runs the workers: Node.js 18+
(the default), Bun, Deno 2 or QuickJS-ng (`qjs`).

## Usage

```js
// priv/js/worker.js — the same file runs on every runtime
const { Worker } = require('portals-worker');

new Worker({ modules: { text_tools: require('./textTools') } }).run();
```

```elixir
children = [
  {Portals.Pool,
   Portals.JavaScript.worker_opts(
     script: Application.app_dir(:my_app, "priv/js/worker.js"),
     runtime: :node, # or :bun, :deno, :quickjs
     name: MyApp.JS,
     size: 4
   )}
]

{:ok, 2} = Portals.Pool.call(MyApp.JS, "text_tools", "word_count", ["hello world"])
```

The [JavaScript guide](https://hexdocs.pm/portals_javascript/javascript.html)
walks through setup, callbacks, messaging, streaming, each runtime's
trade-offs, deployment, gotchas and best practices.

## Development

This package lives in the [Portals monorepo](https://github.com/Ziinc/portals)
under `packages/portals_javascript`. `mix test` runs the shared conformance
and integration suites against the bundled SDK once per runtime; runtimes
that aren't installed are skipped unless `PORTALS_REQUIRE_ALL_RUNTIMES=1`.
See `CONTRIBUTING.md` at the repository root.

## License

MIT
