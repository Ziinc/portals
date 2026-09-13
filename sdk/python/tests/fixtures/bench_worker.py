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
