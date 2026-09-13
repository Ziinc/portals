defmodule Portals.Connection do
  @moduledoc """
  Owns one worker's socket, protocol state machine, and in-flight request
  table (FR-1, FR-2). One `Portals.Connection` GenServer corresponds to
  one launched worker process.

  Lifecycle: allocates a private Unix-domain socket (or, on platforms
  without Unix-socket support, a framed stdio port), launches the worker
  through `Portals.WorkerLifecycle.Port`, accepts its single connection,
  and completes the exact-version `HELLO`/`READY` handshake — all before
  replying to `start_link/1`, so a successfully started connection is
  always immediately usable.

  A worker crash, protocol violation, or handshake failure fails every
  outstanding request with a terminal `%Portals.Error{}` exactly once and
  moves the connection to `:closed`; it never crashes the caller or the
  BEAM. `Portals.Connection` does not restart itself — that is a pool's
  responsibility (Phase 4).
  """

  use GenServer
  require Logger

  alias Portals.{Codec, Error, Handshake, Protocol, Request, SocketDir}
  alias Portals.WorkerLifecycle

  @codec Codec.MessagePack

  defstruct [
    :transport_mod,
    :socket,
    :lifecycle_port,
    :socket_dir,
    :limits,
    :status,
    :worker_info,
    next_request_id: 1,
    pending: %{}
  ]

  # -- Public API -----------------------------------------------------

  @type start_opts :: [
          command: binary,
          args: [binary],
          transport: :unix | :stdio,
          limits: Protocol.limits(),
          connect_timeout: timeout,
          handshake_timeout: timeout,
          name: GenServer.name()
        ]

  @spec start_link(start_opts) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if name = opts[:name], do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec stop(GenServer.server(), timeout) :: :ok
  def stop(conn, deadline_ms \\ 5_000) do
    GenServer.call(conn, {:shutdown, deadline_ms}, deadline_ms + 1_000)
  catch
    :exit, _ -> :ok
  end

  @spec call(GenServer.server(), binary, binary, list, keyword) ::
          {:ok, term} | {:error, Error.t()}
  def call(conn, module, function, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, request} <- async(conn, module, function, args, opts) do
      await(request, timeout)
    end
  end

  @spec call!(GenServer.server(), binary, binary, list, keyword) :: term
  def call!(conn, module, function, args, opts \\ []) do
    case call(conn, module, function, args, opts) do
      {:ok, value} -> value
      {:error, error} -> raise Portals.CallError, error: error
    end
  end

  @spec async(GenServer.server(), binary, binary, list, keyword) ::
          {:ok, Request.t()} | {:error, Error.t()}
  def async(conn, module, function, args, opts \\ []) do
    deadline = Keyword.get(opts, :deadline_ms)
    detached = Keyword.get(opts, :detach, false)
    caller = self()

    GenServer.call(conn, {:dispatch, module, function, args, deadline, caller, detached})
  end

  @doc "Block the calling process until `request` completes or `timeout` elapses."
  @spec await(Request.t(), timeout) :: {:ok, term} | {:error, Error.t()}
  def await(%Request{connection: conn, id: id}, timeout \\ 5_000) do
    receive do
      {:portals_result, ^conn, ^id, result} -> result
    after
      timeout ->
        GenServer.cast(conn, {:local_await_timeout, id})
        {:error, Error.new(:execution_timeout, "no response within #{timeout}ms")}
    end
  end

  @spec cancel(Request.t()) :: :ok
  def cancel(%Request{connection: conn, id: id}) do
    GenServer.cast(conn, {:cancel, id})
  end

  @spec health(GenServer.server()) :: map
  def health(conn), do: GenServer.call(conn, :health)

  # -- GenServer callbacks ---------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    transport_mode = Keyword.get(opts, :transport, :unix)
    limits = Keyword.get(opts, :limits, Protocol.default_limits())
    connect_timeout = Keyword.get(opts, :connect_timeout, 5_000)
    handshake_timeout = Keyword.get(opts, :handshake_timeout, 5_000)

    state = %__MODULE__{
      transport_mod: transport_module(transport_mode),
      limits: limits,
      status: :starting
    }

    case start_worker(opts, transport_mode, connect_timeout, handshake_timeout, state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:dispatch, _m, _f, _a, _d, _caller, _detach},
        _from,
        %{status: :closed} = state
      ) do
    {:reply, {:error, Error.new(:worker_exit, "connection is closed")}, state}
  end

  def handle_call({:dispatch, module, function, args, deadline, caller, detached}, _from, state) do
    id = state.next_request_id
    frame = [Protocol.frame_tag(:call), id, module, function, args | opt_deadline(deadline)]

    case send_frame(state, frame) do
      :ok ->
        monitor_ref = unless detached, do: Process.monitor(caller)
        entry = %{caller: caller, monitor_ref: monitor_ref, cancelled: false}
        state = %{state | next_request_id: id + 1, pending: Map.put(state.pending, id, entry)}
        {:reply, {:ok, %Request{connection: self(), id: id}}, state}

      {:error, reason} ->
        {:reply, {:error, Error.new(:transport, inspect(reason))},
         %{state | next_request_id: id + 1}}
    end
  end

  def handle_call(:health, _from, state) do
    {:reply,
     %{
       status: state.status,
       in_flight: map_size(state.pending),
       worker_info: state.worker_info
     }, state}
  end

  def handle_call({:shutdown, deadline_ms}, _from, state) do
    do_shutdown(state, deadline_ms)
    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  @impl true
  def handle_cast({:cancel, id}, state) do
    case Map.fetch(state.pending, id) do
      {:ok, entry} when not entry.cancelled ->
        _ = send_frame(state, [Protocol.frame_tag(:cancel), id])
        {:noreply, %{state | pending: Map.put(state.pending, id, %{entry | cancelled: true})}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:local_await_timeout, _id}, state), do: {:noreply, state}

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state),
    do: handle_frame_bytes(data, state)

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: fail_all(state, :worker_exit, "worker closed the connection")

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: fail_all(state, :transport, "transport error: #{inspect(reason)}")

  def handle_info({port, {:data, data}}, %{socket: port} = state),
    do: handle_frame_bytes(data, state)

  def handle_info({port, {:exit_status, status}}, %{lifecycle_port: port} = state),
    do: fail_all(state, :worker_exit, "worker exited with status #{status}")

  def handle_info({:EXIT, port, reason}, %{lifecycle_port: port} = state),
    do: fail_all(state, :worker_exit, "worker port exited: #{inspect(reason)}")

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {ids, pending} =
      Enum.reduce(state.pending, {[], state.pending}, fn
        {id, %{monitor_ref: ^ref} = entry}, {ids, acc} ->
          _ = send_frame(state, [Protocol.frame_tag(:cancel), id])
          {[id | ids], Map.put(acc, id, %{entry | cancelled: true})}

        _, acc ->
          acc
      end)

    _ = ids
    {:noreply, %{state | pending: pending}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket_dir, do: SocketDir.cleanup(state.socket_dir)
    :ok
  end

  # -- Startup ----------------------------------------------------------

  defp start_worker(opts, :unix, connect_timeout, handshake_timeout, state) do
    worker_id = "w#{:erlang.unique_integer([:positive, :monotonic])}"

    with {:ok, dir, socket_path} <- SocketDir.allocate(worker_id),
         {:ok, listen_socket} <- Portals.Transport.Unix.listen(socket_path: socket_path),
         {:ok, lifecycle_port} <-
           WorkerLifecycle.Port.launch(
             command: Keyword.fetch!(opts, :command),
             args: Keyword.get(opts, :args, []) ++ [socket_path],
             env: Keyword.get(opts, :env, []),
             cd: Keyword.get(opts, :cd)
           ),
         {:ok, socket} <- Portals.Transport.Unix.accept(listen_socket, connect_timeout),
         :ok <- :gen_tcp.close(listen_socket),
         {:ok, worker_info} <- handshake(socket, :unix, state.limits, handshake_timeout) do
      {:ok,
       %{
         state
         | socket: socket,
           lifecycle_port: lifecycle_port,
           socket_dir: dir,
           status: :ready,
           worker_info: worker_info
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_worker(opts, :stdio, _connect_timeout, handshake_timeout, state) do
    with {:ok, port} <-
           WorkerLifecycle.Port.launch_stdio(
             command: Keyword.fetch!(opts, :command),
             args: Keyword.get(opts, :args, []),
             env: Keyword.get(opts, :env, []),
             cd: Keyword.get(opts, :cd)
           ),
         {:ok, worker_info} <- handshake(port, :stdio, state.limits, handshake_timeout) do
      {:ok,
       %{state | socket: port, lifecycle_port: port, status: :ready, worker_info: worker_info}}
    end
  end

  defp handshake(socket_or_port, mode, limits, timeout) do
    with {:ok, bytes} <- receive_one_frame(socket_or_port, mode, timeout),
         {:ok, envelope, <<>>} <- @codec.decode(bytes, limits),
         {:ok, {:hello, fields}} <- Protocol.validate_envelope(envelope),
         {:ok, hello} <- Handshake.negotiate([Protocol.frame_tag(:hello) | fields]) do
      ready = Handshake.build_ready(limits)
      {:ok, ready_bytes} = @codec.encode(ready, limits)
      :ok = transport_send(socket_or_port, mode, ready_bytes)
      {:ok, hello}
    else
      {:error, reason} -> {:error, {:handshake_failed, reason}}
      other -> {:error, {:handshake_failed, other}}
    end
  end

  defp receive_one_frame(socket, :unix, timeout) do
    receive do
      {:tcp, ^socket, data} -> {:ok, data}
      {:tcp_closed, ^socket} -> {:error, :closed}
      {:tcp_error, ^socket, reason} -> {:error, reason}
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp receive_one_frame(port, :stdio, timeout) do
    receive do
      {^port, {:data, data}} -> {:ok, data}
      {^port, {:exit_status, status}} -> {:error, {:worker_exited, status}}
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp transport_send(socket, :unix, bytes), do: Portals.Transport.Unix.send(socket, bytes)
  defp transport_send(port, :stdio, bytes), do: Portals.Transport.Stdio.send(port, bytes)

  # -- Runtime frame handling ---------------------------------------------

  defp handle_frame_bytes(data, state) do
    case @codec.decode(data, state.limits) do
      {:ok, envelope, <<>>} ->
        dispatch_envelope(envelope, state)

      {:ok, _envelope, _extra} ->
        fail_all(state, :protocol, "frame carried trailing bytes")

      {:error, reason} ->
        fail_all(state, :protocol, "malformed frame: #{inspect(reason)}")
    end
  end

  defp dispatch_envelope(envelope, state) do
    case Protocol.validate_envelope(envelope) do
      {:ok, {:return, [id, value]}} -> resolve(state, id, {:ok, value})
      {:ok, {:error, [id, error_map]}} -> resolve(state, id, {:error, Error.from_wire(error_map)})
      {:ok, {:ping, [nonce]}} -> reply_pong(state, nonce)
      {:ok, {:pong, [_nonce]}} -> {:noreply, state}
      {:ok, {other, _fields}} -> unsupported_frame(state, other)
      {:error, reason} -> fail_all(state, :protocol, "invalid envelope: #{inspect(reason)}")
    end
  end

  defp unsupported_frame(state, frame_name) do
    Logger.warning("Portals.Connection: unsupported frame #{inspect(frame_name)} ignored")
    {:noreply, state}
  end

  defp reply_pong(state, nonce) do
    _ = send_frame(state, [Protocol.frame_tag(:pong), nonce])
    {:noreply, state}
  end

  defp resolve(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        if entry.monitor_ref, do: Process.demonitor(entry.monitor_ref, [:flush])
        send(entry.caller, {:portals_result, self(), id, result})
        {:noreply, %{state | pending: pending}}
    end
  end

  defp fail_all(state, kind, message) do
    error = Error.new(kind, message)

    Enum.each(state.pending, fn {id, entry} ->
      if entry.monitor_ref, do: Process.demonitor(entry.monitor_ref, [:flush])
      send(entry.caller, {:portals_result, self(), id, {:error, error}})
    end)

    {:noreply, %{state | pending: %{}, status: :closed}}
  end

  defp do_shutdown(state, deadline_ms) do
    _ = send_frame(state, [Protocol.frame_tag(:shutdown)])
    if state.lifecycle_port, do: WorkerLifecycle.Port.terminate(state.lifecycle_port, deadline_ms)

    if state.socket && state.transport_mod == Portals.Transport.Unix,
      do: state.transport_mod.close(state.socket)

    :ok
  end

  defp send_frame(state, frame) do
    with {:ok, bytes} <- @codec.encode(frame, state.limits) do
      state.transport_mod.send(state.socket, bytes)
    end
  end

  defp opt_deadline(nil), do: []
  defp opt_deadline(ms), do: [ms]

  defp transport_module(:unix), do: Portals.Transport.Unix
  defp transport_module(:stdio), do: Portals.Transport.Stdio
end
