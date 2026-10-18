# hello_live

A Phoenix LiveView page that calls a hello-world function in six
languages: Python, Ruby, Node.js, PHP, Java and Go. Each runs in its own
supervised `Portals.Pool`, and the six calls run concurrently, so each
reply appears as soon as its runtime answers.

![The hello_live demo](demo/hello_live.gif)

## Run it

You need Elixir 1.15+ and the six runtimes: `python3`, `ruby`, `node`,
`php`, a JDK 17+ (`java`, `javac`) and `go`.

```sh
cd examples/hello_live
mix deps.get
mix phx.server
```

Open <http://localhost:4000>. `mix compile` also builds the two compiled
workers: the Java classes into `priv/java/classes` and the Go binary into
`priv/bin/greeter_go` (see `lib/mix/tasks/hello_live.build_workers.ex`).

`mix test` drives the page with `Phoenix.LiveViewTest` and checks that
every language replies.

## How it fits together

| Language | Worker | Launched with |
|---|---|---|
| Python | `priv/python/greeter.py`, `worker.py` | `Portals.Python.worker_opts(script: ...)` |
| Ruby | `priv/ruby/greeter.rb`, `worker.rb` | `Portals.Ruby.worker_opts(script: ...)` |
| Node.js | `priv/node/greeter.js`, `worker.js` | `Portals.Node.worker_opts(script: ...)` |
| PHP | `priv/php/Greeter.php`, `worker.php` | `Portals.PHP.worker_opts(script: ...)` |
| Java | `priv/java/src/greeter/*.java` | `Portals.Java.worker_opts(main: "greeter.RunWorker", ...)` |
| Go | `go/main.go` | `Portals.Go.worker_opts(binary: ...)` |

- `lib/hello_live/languages.ex` starts one pool per language (each with its
  own child id) and times each `Portals.Pool.call/5`.
- `lib/hello_live_web/live/hello_live.ex` runs every call with
  `start_async/3`, so a slow runtime never holds up the others.
- The page loads the Phoenix and LiveView JavaScript clients straight from
  their packages (`lib/hello_live_web/endpoint.ex`), so there is no asset
  pipeline.

This example depends on the packages in this repository by path. In your
own app, depend on the Hex releases instead, e.g. `{:portals_python, "~>
0.1.0"}`, and point the Go `replace` directive at
`../deps/portals_go/priv/go`.

## Re-recording the GIF

With the server running:

```sh
NODE_PATH=$(npm root -g) node scripts/record_demo.js
```

This needs the `playwright` npm package and `ffmpeg`, and writes
`demo/hello_live.gif`, which the README and hexdocs embed.
