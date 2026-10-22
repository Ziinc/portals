"""zerorpc server serving `bench_handlers` on tcp://127.0.0.1:<port>."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import zerorpc  # noqa: E402

import bench_handlers  # noqa: E402


class Handlers:
    echo = staticmethod(bench_handlers.echo)
    add = staticmethod(bench_handlers.add)


if __name__ == "__main__":
    server = zerorpc.Server(Handlers())
    server.bind(f"tcp://127.0.0.1:{sys.argv[1]}")
    print("ready", flush=True)
    server.run()
