# portals_python

Python worker SDK for [Portals](https://hexdocs.pm/portals): call Python code
from Elixir in supervised, pooled OS processes.

This package bundles the Python worker SDK under `priv/python/` (the `portals` Python package, put on `PYTHONPATH`) and provides
`Portals.Python`, which builds the launch options for `Portals.start_worker/1` and
`Portals.Pool`. Nothing is installed from a Python package registry: the SDK
comes from Hex, versioned in lockstep with `portals`.

## Installation

```elixir
def deps do
  [
    {:portals_python, "~> 0.1.0"}
  ]
end
```

`portals_python` depends on `portals`, so this one line is enough. You need
Python 3 on the machine that runs the workers (the SDK is tested on 3.13).

## Usage

```python
# priv/python/worker.py
from portals import Worker

Worker().run()
```

```elixir
children = [
    {Portals.Pool,
     Portals.Python.worker_opts(
       script: Application.app_dir(:my_app, "priv/python/worker.py"),
       name: MyApp.Python,
       size: 4
     )}
]

{:ok, 2} = Portals.Pool.call(MyApp.Python, "text_tools", "word_count", ["hello world"])
```

The [Python guide](https://hexdocs.pm/portals_python/python.html) walks
through setup, callbacks, messaging, streaming, deployment, gotchas and
best practices.

## Development

This package lives in the [Portals monorepo](https://github.com/Ziinc/portals)
under `packages/portals_python`. `mix test` runs the shared conformance and
integration suites against the bundled SDK; see `CONTRIBUTING.md` at the
repository root.

## License

MIT
