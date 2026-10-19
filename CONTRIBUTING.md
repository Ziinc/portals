# Contributing

Portals is a monorepo of seven Mix projects: core `portals` at the root and
one package per language under `packages/`. Each language package depends
on core by path while it is inside this repository (detected through the
`.portals-monorepo` marker file), and on the matching Hex release once
published.

## Layout

```text
lib/                              core: Portals, Portals.Pool, Portals.Connection, ...
lib/portals/conformance/          the conformance kit every SDK is tested with
lib/mix/tasks/                    mix portals.sdk_path
protocol/                         wire protocol v1, golden vectors, malformed fixtures
test/                             core tests (they launch the Python SDK's fixture worker)
guides/                           hexdocs guides; guides/languages/<language>.md
packages/portals_<language>/
  lib/portals/<language>.ex       Portals.<Language>: sdk_path/0 and worker_opts/1
  priv/<language>/                the worker SDK, its unit tests and fixtures
  test/worker_suite_test.exs      Portals.Conformance.WorkerSuite against the SDK
  test/conformance_test.exs       Portals.Conformance.SDKSuite against the SDK
  test/guide/ + guide_test.exs    the language guide's example, run end to end
examples/hello_live/              a Phoenix LiveView app calling all six languages
scripts/                          test_all.sh, version.exs, release.sh, hex_dry_run.sh, publish_hex.sh
```

Only `lib/`, the runtime part of `priv/`, `mix.exs`, `README.md` and
`LICENSE` are published. SDK unit tests and fixtures stay in the repository.

## Running the tests

```sh
scripts/test_all.sh            # core + every language: format, warnings, tests, SDK unit tests
scripts/test_all.sh python go  # core + just these languages
```

You need Elixir, plus the toolchain of each language you test: `python3`,
`ruby`, `node` (plus `bun`, `deno` and `qjs` for the other JavaScript
runtimes), `php`, `java`/`javac` 17+ and `go`. Inside one package,
`mix test` runs its Elixir suites. Each SDK's own unit tests run with that
language's tooling, as listed in `scripts/test_all.sh`.

Core's tests use the Python SDK from `packages/portals_python`, so core
needs `python3` too.

`scripts/test_all.sh` also runs `examples/hello_live`'s tests when every
language is selected and Elixir is 1.15+ (Phoenix LiveView's minimum). If
you change the page, re-record its GIF as described in that example's
README.

## CI

`.github/workflows/ci.yml` runs on every pull request, on `main`, and as
the first stage of every release (`.github/workflows/release.yml`, see
RELEASING.md), using the same scripts you run locally:

| Job | Runs |
|---|---|
| Lint | `scripts/lint.sh` (ruff, `ruby -wc`, `node --check`, `php -l`, `javac -Xlint`, gofmt and `go vet`, shellcheck) and actionlint |
| Core | `scripts/check_project.sh .` on Elixir 1.14/OTP 25 and 1.18/OTP 27 |
| `portals_<language>` | `scripts/check_project.sh packages/portals_<language>` and `scripts/sdk_tests.sh <language>`, one job per language. JavaScript installs Node.js, Bun, Deno and QuickJS and runs on all four. |
| examples/hello_live | `scripts/check_project.sh examples/hello_live` with every runtime |
| Release dry run | `scripts/hex_dry_run.sh`: version check, ExDoc for every package with warnings as errors, `mix hex.publish --dry-run` for core and a publish-mode `mix hex.build` for each language package. The tarballs are kept as the `hex-packages` artifact. |

`scripts/check_project.sh` is formatting, unused locked dependencies,
`--warnings-as-errors` compilation and `mix test`.

## Changing an SDK

Every SDK must keep passing `Portals.Conformance.WorkerSuite` and
`Portals.Conformance.SDKSuite`, the same black-box expectations for every
language. When you add a behaviour, add it to the shared suites (and to
every SDK's `bench_worker` fixture), not to one language's tests.

The code in each language guide is the code in that package's
`test/guide/`. `test/unit/guides_test.exs` fails if they drift apart, so
edit both together.

## Adding a language

1. Implement `protocol/v1.md` in a new SDK under
   `packages/portals_<language>/priv/<language>/`, with `bench_worker` and
   `conformance_worker` fixtures mirroring the existing SDKs'.
2. Add `Portals.<Language>` implementing `Portals.SDK` (`sdk_path/0`,
   `worker_opts/1`), and register it in `Portals.SDK.languages/0`.
3. Copy another package's `mix.exs` and `test/` and point them at the new
   SDK: `use Portals.Conformance.WorkerSuite` and `use Portals.Conformance.SDKSuite`.
4. Write `guides/languages/<language>.md` around a tested `test/guide/`
   example, and add the guide to core's `mix.exs` docs.
5. Add the SDK's version constant to `scripts/version.exs`, the language
   to `scripts/test_all.sh`, `scripts/hex_dry_run.sh` and
   `scripts/publish_hex.sh`, and the package to the README.
