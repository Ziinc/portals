defmodule Portals.Transport.Unix do
  @moduledoc """
  Default transport: one BEAM-created Unix-domain socket per worker.

  The BEAM listens before the worker is launched (FR-1); the worker
  connects once, using the socket path passed as a plain command-line
  argument (never shell-interpolated). Delivers data as standard
  `:gen_tcp` active-mode messages (`{:tcp, socket, data}`,
  `{:tcp_closed, socket}`, `{:tcp_error, socket, reason}`) to whichever
  process calls `accept/2`, so a GenServer can `handle_info/2` them
  directly.
  """

  @behaviour Portals.Transport

  @impl true
  def listen(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)

    :gen_tcp.listen(0, [
      :binary,
      active: false,
      packet: 4,
      ifaddr: {:local, socket_path},
      backlog: 1
    ])
  end

  @impl true
  def accept(listen_socket, timeout) do
    with {:ok, socket} <- :gen_tcp.accept(listen_socket, timeout) do
      :inet.setopts(socket, active: true)
      {:ok, socket}
    end
  end

  @impl true
  def send(socket, data), do: :gen_tcp.send(socket, data)

  @impl true
  def close(socket), do: :gen_tcp.close(socket)
end
