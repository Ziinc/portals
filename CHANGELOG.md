# Changelog

All packages (`portals` and every `portals_<language>`) share one version
and one changelog.

## Unreleased

- Split the worker SDKs out of core into one Hex package per language:
  `portals_python`, `portals_ruby`, `portals_javascript`, `portals_php`,
  `portals_java` and `portals_go`. Each provides `Portals.<Language>` with
  `sdk_path/0` and `worker_opts/1`, which put the bundled SDK on the
  worker's import path. Core `portals` ships no SDKs.
- `Portals.SDK` behaviour and `mix portals.sdk_path <language>`.
- Conformance kit: `Portals.Conformance.WorkerSuite` and
  `Portals.Conformance.SDKSuite`, the shared suites every SDK must pass.
- Python SDK: `portals.cancelled()`, `portals.current_deadline_ms()` and
  `portals.__version__`, bringing it to parity with the other SDKs.
- Ruby SDK: exception messages and backtraces are sent as text. Previously
  they arrived in Elixir as an inspected `%Portals.Codec.Bin{}`.
- `portals_javascript` (formerly the Node.js SDK) runs the same worker
  scripts on Node.js, Bun, Deno or QuickJS, chosen with
  `Portals.JavaScript.worker_opts(runtime: ...)`. QuickJS runs through a
  bundled host that provides the Node APIs the SDK uses, over the stdio
  transport. Every runtime passes the full conformance suite.
- Hexdocs: a getting-started guide and one guide per language.
- Go SDK: distributed only inside `portals_go` (no Go module tags).
