defmodule Bench.ZeroRPC do
  @moduledoc """
  A minimal zerorpc client: the zerorpc protocol (v3) over a ZeroMQ DEALER
  socket from chumak, the pure-Erlang ZeroMQ implementation, with Msgpax
  as the MessagePack codec.

  Each call is the event `[%{"message_id" => id, "v" => 3}, method, args]`;
  the server answers on the same channel with `"OK"` (`[result]`) or
  `"ERR"`. Channel housekeeping events (`_zpc_hb` heartbeats, `_zpc_more`
  flow control) are ignored, as calls finish long before a heartbeat is
  due. Calls are multiplexed over the one socket, like the Python client.
  """

  use GenServer

  def start_link(port), do: GenServer.start_link(__MODULE__, port)

  def call(client, method, args, timeout \\ 30_000) do
    GenServer.call(client, {:call, method, args}, timeout)
  end

  @impl true
  def init(port) do
    {:ok, socket} = :chumak.socket(:dealer)
    {:ok, peer} = :chumak.connect(socket, :tcp, ~c"127.0.0.1", port)
    owner = self()
    receiver = spawn_link(fn -> receive_loop(socket, owner) end)
    {:ok, %{socket: socket, peer: peer, receiver: receiver, next_id: 0, pending: %{}}}
  end

  @impl true
  def handle_call({:call, method, args}, from, state) do
    id = <<state.next_id::64>>
    header = %{"message_id" => Msgpax.Bin.new(id), "v" => 3}
    event = Msgpax.pack!([header, method, args], iodata: false)
    :ok = :chumak.send_multipart(state.socket, ["", event])
    {:noreply, %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_info({:event, blob}, state) do
    [header, name, args] = Msgpax.unpack!(blob)

    case Map.pop(state.pending, header["response_to"]) do
      {from, pending} when name in ["OK", "ERR"] and from != nil ->
        GenServer.reply(from, if(name == "OK", do: {:ok, hd(args)}, else: {:error, args}))
        {:noreply, %{state | pending: pending}}

      _housekeeping ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Process.unlink(state.receiver)
    Process.exit(state.receiver, :kill)
    # The peer (connection) outlives its socket and would keep reconnecting.
    :chumak_peer.close(state.peer)
    GenServer.stop(state.socket)
  end

  defp receive_loop(socket, owner) do
    {:ok, frames} = :chumak.recv_multipart(socket)
    send(owner, {:event, List.last(frames)})
    receive_loop(socket, owner)
  end
end
