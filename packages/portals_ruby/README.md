# portals_ruby

Ruby worker SDK for [Portals](https://hexdocs.pm/portals): call Ruby code
from Elixir in supervised, pooled OS processes.

This package bundles the Ruby worker SDK under `priv/ruby/lib` (put on `RUBYLIB`) and provides
`Portals.Ruby`, which builds the launch options for `Portals.start_worker/1` and
`Portals.Pool`. Nothing is installed from a Ruby package registry: the SDK
comes from Hex, versioned in lockstep with `portals`.

## Installation

```elixir
def deps do
  [
    {:portals_ruby, "~> 0.1.0"}
  ]
end
```

`portals_ruby` depends on `portals`, so this one line is enough. You need
Ruby 3.0+ on the machine that runs the workers (tested on 3.3).

## Usage

```ruby
# priv/ruby/worker.rb
require 'portals'
require_relative 'text_tools'

Portals::Worker.new(modules: { 'text_tools' => TextTools }).run
```

```elixir
children = [
    {Portals.Pool,
     Portals.Ruby.worker_opts(
       script: Application.app_dir(:my_app, "priv/ruby/worker.rb"),
       name: MyApp.Ruby,
       size: 4
     )}
]

{:ok, 2} = Portals.Pool.call(MyApp.Ruby, "text_tools", "word_count", ["hello world"])
```

The [Ruby guide](https://hexdocs.pm/portals_ruby/ruby.html) walks
through setup, callbacks, messaging, streaming, deployment, gotchas and
best practices.

## Development

This package lives in the [Portals monorepo](https://github.com/Ziinc/portals)
under `packages/portals_ruby`. `mix test` runs the shared conformance and
integration suites against the bundled SDK; see `CONTRIBUTING.md` at the
repository root.

## License

MIT
