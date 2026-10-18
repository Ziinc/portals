# Changelog

All packages (`portals` and every `portals_<language>`) share one version
and one changelog.

## Unreleased

- Split the worker SDKs out of core into one Hex package per language:
  `portals_python`, `portals_ruby`, `portals_node`, `portals_php`,
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
- Hexdocs: a getting-started guide and one guide per language.
- Go SDK: distributed only inside `portals_go` (no Go module tags).
