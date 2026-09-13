"""Structured remote-error mapping (FR-4). Every uncaught exception raised
by a called function is turned into an `ERROR` frame carrying language,
exception type, message, and a normalized, bounded stack trace — never a
raw pickled/arbitrary object.
"""

import traceback

MAX_STACK_FRAMES = 64
MAX_MESSAGE_SIZE = 4096


def build_error_map(exc: BaseException) -> dict:
    message = str(exc)
    if len(message.encode("utf-8", errors="replace")) > MAX_MESSAGE_SIZE:
        message = message[:MAX_MESSAGE_SIZE]

    frames = traceback.format_exception(type(exc), exc, exc.__traceback__)
    frames = frames[-MAX_STACK_FRAMES:]

    return {
        "kind": "remote",
        "message": message or type(exc).__name__,
        "details": {},
        "remote": {
            "language": "python",
            "exception_type": type(exc).__name__,
        },
        "stacktrace": frames,
    }
