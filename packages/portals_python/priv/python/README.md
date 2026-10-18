# Portals Python worker SDK

A Python worker for [Portals](../../../../README.md), implementing the v1
wire protocol in [`protocol/v1.md`](../../../../protocol/v1.md). It is the
reference SDK the others are checked against.

This SDK ships inside the `portals_python` Hex package, which also puts it
on the worker's `PYTHONPATH`. **Application developers should start with
the [Python guide](../../../../guides/languages/python.md)**; this README
documents the SDK itself.

Standard library only: the MessagePack codec (including the Erlang value
extensions) is pure Python in `portals/msgpack_codec.py`.

## Layout

| Module | Contents |
|---|---|
| `portals/worker.py` | `Worker`, the dispatcher (a reader thread plus call and stream thread pools), `callback`, `send_message`, `cancelled`, `current_deadline_ms` |
| `portals/streams.py` | `Stream`, `stream_handler`, byte-credit and frame-count accounting |
| `portals/msgpack_codec.py` | Encoder and decoder with the Erlang value extensions and limits |
| `portals/values.py` | `Atom`, `Pid`, `Reference`, `ImproperList` |
| `portals/transport.py` | Unix-socket and framed-stdio transports |
| `portals/errors.py` | Exception to `ERROR` frame mapping |

## Tests

```sh
python3 -m unittest discover -s tests
```

The cross-language conformance and integration suites live on the Elixir
side: run `mix test` in `packages/portals_python`, or
`scripts/test_all.sh python` from the repository root.
