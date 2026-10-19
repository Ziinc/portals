defmodule Bench.Targets do
  @moduledoc """
  Every way the suite calls the same Python functions (`bench_handlers`):
  Portals over each codec and transport, zerorpc and ErlPort.

  A target is a map of `:start` (returns a handle), `:call` (handle,
  function name, args) returning the result, `:stop`, and `:wrap_bytes`,
  which turns raw bytes into that library's binary type.
  """

  alias Bench.Python

  @doc "The RPC targets compared in rpc.exs, in report order."
  def rpc do
    [
      {"Portals: ETF, Unix socket", portals(transport: :unix)},
      {"Portals: ETF, Unix socket, inline", portals(transport: :unix, inline: true)},
      {"Portals: ETF, stdio", portals(transport: :stdio)},
      {"Portals: ETF, stdio, inline", portals(transport: :stdio, inline: true)},
      {"Portals: MessagePack, Unix socket", portals(transport: :unix, codec: :msgpack)},
      {"Portals: MessagePack, stdio", portals(transport: :stdio, codec: :msgpack)},
      {"zerorpc: MessagePack, ZeroMQ/TCP", zerorpc()},
      {"ErlPort: ETF, stdio", erlport()}
    ]
  end

  @doc "Portals, optionally as a pool of `:size` workers and with `inline: true` calls."
  def portals(opts) do
    transport = Keyword.get(opts, :transport, :unix)
    size = opts[:size]
    call_opts = [timeout: 60_000, inline: Keyword.get(opts, :inline, false)]

    codec = Keyword.get(opts, :codec, :etf)

    worker_opts =
      Portals.Python.worker_opts(
        [
          script: Python.script("portals_worker.py"),
          python: Python.executable(),
          transport: transport,
          args: [Atom.to_string(transport)],
          codec: codec
        ] ++ if(size, do: [size: size], else: [])
      )

    {start, call} =
      if size do
        {fn -> Portals.start_pool(worker_opts) end, &Portals.Pool.call/5}
      else
        {fn -> Portals.start_worker(worker_opts) end, &Portals.call/5}
      end

    %{
      start: fn ->
        {:ok, pid} = start.()
        Process.unlink(pid)
        pid
      end,
      call: fn pid, function, args ->
        {:ok, result} = call.(pid, "bench_handlers", function, args, call_opts)
        result
      end,
      stop: fn pid -> GenServer.stop(pid) end,
      wrap_bytes: &%Portals.Codec.Bin{data: &1}
    }
  end

  def zerorpc do
    %{
      start: fn ->
        tcp_port = Python.free_port()

        server =
          Python.spawn("zerorpc_server.py", [Integer.to_string(tcp_port)], wait_for_ready: true)

        {:ok, client} = Bench.ZeroRPC.start_link(tcp_port)
        Process.unlink(client)
        {server, client}
      end,
      call: fn {_server, client}, function, args ->
        {:ok, result} = Bench.ZeroRPC.call(client, function, args, 60_000)
        result
      end,
      stop: fn {server, client} ->
        GenServer.stop(client)
        Python.kill(server)
      end,
      wrap_bytes: &Msgpax.Bin.new/1
    }
  end

  @doc "ErlPort, optionally as `:instances` interpreters called round-robin."
  def erlport(opts \\ []) do
    instances = Keyword.get(opts, :instances, 1)

    %{
      start: fn ->
        pythons =
          for _ <- 1..instances do
            {:ok, python} =
              :python.start(
                python: String.to_charlist(Python.executable()),
                python_path: String.to_charlist(Python.dir())
              )

            Process.unlink(python)
            python
          end

        {List.to_tuple(pythons), :counters.new(1, [])}
      end,
      call: fn {pythons, counter}, function, args ->
        :counters.add(counter, 1, 1)
        python = elem(pythons, rem(:counters.get(counter, 1), tuple_size(pythons)))
        :python.call(python, :bench_handlers, String.to_atom(function), args)
      end,
      stop: fn {pythons, _} -> pythons |> Tuple.to_list() |> Enum.each(&:python.stop/1) end,
      wrap_bytes: & &1
    }
  end
end
