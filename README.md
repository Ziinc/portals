# portals
The spiritual erlport successor

See [`docs/prd.md`](docs/prd.md) for the full product/engineering PRD and
delivery plan.

## Status

Phase 1 (value model, protocol, and conformance) is implemented:

- `protocol/v1.md` — the language-neutral wire protocol specification.
- `lib/portals/protocol.ex` — frame tags, arities, and default limits.
- `lib/portals/codec/message_pack.ex` — the mandatory MessagePack codec,
  including the Erlang-value extensions in `lib/portals/term_extensions.ex`.
- `lib/portals/handshake.ex` — exact-version `HELLO`/`READY` negotiation.
- `lib/portals/conformance/runner.ex` — the black-box conformance runner,
  driven by `protocol/vectors/golden.exs` and `protocol/malformed/fixtures.exs`.

Run the test suite with `mix test`.
