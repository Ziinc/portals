# portals_php

PHP worker SDK for [Portals](https://hexdocs.pm/portals): call PHP code
from Elixir in supervised, pooled OS processes.

This package bundles the PHP worker SDK under `priv/php/src` (preloaded with `auto_prepend_file`) and provides
`Portals.PHP`, which builds the launch options for `Portals.start_worker/1` and
`Portals.Pool`. Nothing is installed from a PHP package registry: the SDK
comes from Hex, versioned in lockstep with `portals`.

## Installation

```elixir
def deps do
  [
    {:portals_php, "~> 0.1.0"}
  ]
end
```

`portals_php` depends on `portals`, so this one line is enough. You need
PHP 8.1+ (64-bit) on the machine that runs the workers.

## Usage

```php
<?php
// priv/php/worker.php — the SDK is preloaded with auto_prepend_file
require __DIR__ . '/TextTools.php';

(new Portals\Worker(modules: ['text_tools' => TextTools::class]))->run();
```

```elixir
children = [
    {Portals.Pool,
     Portals.PHP.worker_opts(
       script: Application.app_dir(:my_app, "priv/php/worker.php"),
       name: MyApp.PHP,
       size: 4
     )}
]

{:ok, 2} = Portals.Pool.call(MyApp.PHP, "text_tools", "word_count", ["hello world"])
```

The [PHP guide](https://hexdocs.pm/portals_php/php.html) walks
through setup, callbacks, messaging, streaming, deployment, gotchas and
best practices.

## Development

This package lives in the [Portals monorepo](https://github.com/Ziinc/portals)
under `packages/portals_php`. `mix test` runs the shared conformance and
integration suites against the bundled SDK; see `CONTRIBUTING.md` at the
repository root.

## License

MIT
