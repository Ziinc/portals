"""Function targets used by the Elixir integration tests and by the
ErlPort/ZeroMQ benchmark suites (Phase 8)."""

import time

import portals


def echo(value):
    return value


def add(a, b):
    return a + b


def raise_error(message):
    raise ValueError(message)


def sleep_ms(ms):
    time.sleep(ms / 1000)
    return ms


def crash_process():
    import os

    os._exit(1)


def double_via_callback(n):
    """Calls back into the BEAM to double a number, demonstrating a
    reentrant round trip (Python -> Elixir -> Python is exercised
    separately by `nested_call_then_callback`)."""

    return portals.callback("Elixir.Portals.Fixtures.CallbackTarget", "double", [n])


def nested_call_then_callback(conn_marker, n):
    """A callback target the Elixir side invokes; while running (still
    inside the BEAM-side callback handler), it issues a *nested* CALL
    back into this same worker, whose handler in turn issues its own
    callback — demonstrating full reentrancy at depth > 1."""

    depth_here = portals.current_callback_depth()
    return {"depth_seen": depth_here, "doubled": n * 2}


def callback_depth_probe():
    return portals.current_callback_depth()


def message_to_caller(pid, value):
    portals.send_message(pid, value)
    return "sent"


def raise_callback_error():
    return portals.callback("Elixir.Portals.Fixtures.CallbackTarget", "boom", [])


# -- Streaming targets (Phase 6) ---------------------------------------


@portals.stream_handler
def echo_stream(stream):
    """Echo every inbound chunk back out, then terminate with a count."""

    count = 0
    for chunk in stream:
        stream.send(chunk)
        count += 1
    return count


@portals.stream_handler
def produce_stream(stream, count, size):
    """Produce `count` chunks of `size` bytes each. Blocks on the BEAM's
    credit window, so a BEAM consumer that stops consuming stops this
    producer without either side buffering without bound."""

    payload = "x" * size
    for _ in range(count):
        stream.send(payload, timeout=10)
    stream.half_close()
    return count


@portals.stream_handler
def drain_stream(stream, delay_ms=0):
    """Consume everything the BEAM sends, optionally slowly, and report
    how many chunks and bytes arrived."""

    chunks = 0
    total = 0
    for chunk in stream:
        chunks += 1
        total += len(chunk)
        if delay_ms:
            time.sleep(delay_ms / 1000)
    return {"chunks": chunks, "bytes": total}


@portals.stream_handler
def never_consume(stream, hold_ms):
    """Never consume inbound chunks: the BEAM's sender must block on the
    credit window rather than grow BEAM memory."""

    time.sleep(hold_ms / 1000)
    return "held"


@portals.stream_handler
def half_close_then_drain(stream):
    """Close only the worker's sending direction immediately, then keep
    consuming inbound chunks — proving half-close is per-direction."""

    stream.half_close()
    chunks = 0
    for _ in stream:
        chunks += 1
    return chunks


@portals.stream_handler
def hold_stream(stream, hold_ms):
    """Keep a stream open (and a stream-pool thread busy) without doing
    anything, for unary/stream fairness tests."""

    time.sleep(hold_ms / 1000)
    return "done"
