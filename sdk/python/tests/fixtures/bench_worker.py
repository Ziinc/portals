"""Function targets used by the Elixir integration tests and by the
ErlPort/ZeroMQ benchmark suites (Phase 8)."""

import time


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
