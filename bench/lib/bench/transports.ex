defmodule Bench.Transports do
  @moduledoc """
  Raw transports, with no codec and no RPC: the BEAM sends a frame and
  waits for the Python echo server (`python/echo_server.py`) to send it
  back. This is the floor each RPC stack builds on.

  Each transport is a map of `:start`, `:round_trip` (handle, binary),
  `:stop`, and `:claim` / `:release`, which lend the handle to the calling
  process (a Port only delivers data to its owner, and Benchee measures in
  a fresh process per scenario).
  """

  alias Bench.Python

  def all do
    [
      {"Unix socket", stream(:unix)},
      {"TCP loopback", stream(:tcp)},
      {"stdio (Port)", stdio()},
      {"ZeroMQ/TCP (chumak)", zeromq()}
    ]
  end

  # Unix socket or TCP: the BEAM listens and the echo server connects, as
  # Portals does. 4-byte length framing on both.
  defp stream(kind) do
    %{
      start: fn ->
        {listen, endpoint} = listen(kind)
        echo = Python.spawn("echo_server.py", [Atom.to_string(kind), endpoint])
        {:ok, socket} = :gen_tcp.accept(listen, 30_000)
        :gen_tcp.close(listen)
        {echo, socket}
      end,
      round_trip: fn {_echo, socket}, frame ->
        :ok = :gen_tcp.send(socket, frame)
        {:ok, reply} = :gen_tcp.recv(socket, 0, 30_000)
        reply
      end,
      stop: fn {echo, socket} ->
        :gen_tcp.close(socket)
        Python.kill(echo)
      end,
      claim: fn _ -> :ok end,
      release: fn _ -> :ok end
    }
  end

  defp listen(:unix) do
    path =
      Path.join(System.tmp_dir!(), "portals-bench-#{System.unique_integer([:positive])}.sock")

    File.rm(path)
    {:ok, listen} = :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | socket_opts()])
    {listen, path}
  end

  defp listen(:tcp) do
    {:ok, listen} = :gen_tcp.listen(0, [{:ip, {127, 0, 0, 1}}, {:nodelay, true} | socket_opts()])
    {:ok, port} = :inet.port(listen)
    {listen, Integer.to_string(port)}
  end

  defp socket_opts, do: [:binary, packet: 4, active: false, reuseaddr: true]

  # The script process owns the port between scenarios; each scenario
  # takes it over (claim) and hands it back (release) before exiting, since
  # a port closes when its owner exits.
  defp stdio do
    %{
      start: fn ->
        {Python.spawn("echo_server.py", ["stdio"], port_opts: [{:packet, 4}]), self()}
      end,
      round_trip: fn {port, _home}, frame ->
        true = Port.command(port, frame)

        receive do
          {^port, {:data, reply}} -> reply
        after
          30_000 -> raise "stdio echo timed out"
        end
      end,
      stop: fn {port, _home} -> Python.kill(port) end,
      claim: fn {port, _home} -> connect(port, self()) end,
      release: fn {port, home} -> connect(port, home) end
    }
  end

  defp connect(port, pid) do
    true = Port.connect(port, pid)
    :ok
  end

  defp zeromq do
    %{
      start: fn ->
        tcp_port = Python.free_port()

        echo =
          Python.spawn("echo_server.py", ["zmq", Integer.to_string(tcp_port)],
            wait_for_ready: true
          )

        {:ok, socket} = :chumak.socket(:dealer)
        {:ok, peer} = :chumak.connect(socket, :tcp, ~c"127.0.0.1", tcp_port)
        {echo, socket, peer}
      end,
      round_trip: fn {_echo, socket, _peer}, frame ->
        :ok = :chumak.send_multipart(socket, [frame])
        {:ok, [reply]} = :chumak.recv_multipart(socket)
        reply
      end,
      stop: fn {echo, socket, peer} ->
        # The peer (connection) outlives its socket and would keep reconnecting.
        :chumak_peer.close(peer)
        GenServer.stop(socket)
        Python.kill(echo)
      end,
      claim: fn _ -> :ok end,
      release: fn _ -> :ok end
    }
  end
end
