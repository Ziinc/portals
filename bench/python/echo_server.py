"""Raw transport echo: every 4-byte-length-prefixed frame is sent back
unchanged, with no decoding. One of:

    echo_server.py unix <path>   connect to a Unix socket
    echo_server.py tcp <port>    connect to 127.0.0.1:<port>
    echo_server.py stdio         read stdin, write stdout
    echo_server.py zmq <port>    ZeroMQ ROUTER bound to tcp://127.0.0.1:<port>
"""

import os
import socket
import struct
import sys


def recv_exact(read, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = read(n - len(buf))
        if not chunk:
            sys.exit(0)
        buf += chunk
    return bytes(buf)


def serve_stream(read, write):
    while True:
        header = recv_exact(read, 4)
        (n,) = struct.unpack(">I", header)
        write(header + recv_exact(read, n))


def main(mode, *args):
    if mode in ("unix", "tcp"):
        if mode == "unix":
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(args[0])
        else:
            sock = socket.create_connection(("127.0.0.1", int(args[0])))
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        serve_stream(sock.recv, sock.sendall)
    elif mode == "stdio":
        def write(data):
            view = memoryview(data)
            while view:
                view = view[os.write(1, view) :]

        serve_stream(lambda n: os.read(0, n), write)
    elif mode == "zmq":
        import zmq

        router = zmq.Context().socket(zmq.ROUTER)
        router.bind(f"tcp://127.0.0.1:{args[0]}")
        print("ready", flush=True)
        while True:
            router.send_multipart(router.recv_multipart(copy=False), copy=False)
    else:
        sys.exit(f"unknown mode {mode}")


if __name__ == "__main__":
    main(*sys.argv[1:])
