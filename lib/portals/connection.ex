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
    :callback_sup,
    :callback_allowlist,
    message_envelope: :wrapped,
    next_request_id: 1,
    pending: %{},
    callback_tasks: %{}
  ]

  # -- Public API -----------------------------------------------------

  @type start_opts :: [
          command: binary,
          args: [binary],
          transport: :unix | :stdio,
          limits: Protocol.limits(),
          connect_timeout: timeout,
          handshake_timeout: timeout,
          name: GenServer.name(),
          callback_allowlist: [{module, atom, arity}] | nil,
          message_envelope: :wrapped | :raw
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
    caller = Keyword.get(opts, :caller, self())
    pool_notify = Keyword.get(opts, :pool_notify)
    # Propagated automatically so a nested call made from within a
    # callback handler (see Portals.Callback.depth/0) carries the
    # reentrancy depth the worker should echo back on its own next
    # CALLBACK, per protocol/v1.md section 8.
    callback_depth = Process.get(:portals_callback_depth, 0)

    GenServer.call(
      conn,
      {:dispatch, module, function, args, deadline, callback_depth, caller, detached, pool_notify}
    )
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
    {:ok, callback_sup} = Task.Supervisor.start_link()

    state = %__MODULE__{
      transport_mod: transport_module(transport_mode),
      limits: limits,
      status: :starting,
      callback_sup: callback_sup,
      callback_allowlist: Keyword.get(opts, :callback_allowlist),
      message_envelope: Keyword.get(opts, :message_envelope, :wrapped)
    }

    case start_worker(opts, transport_mode, connect_timeout, handshake_timeout, state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:dispatch, _m, _f, _a, _d, _cd, _caller, _detach, _pool_notify},
        _from,
        %{status: :closed} = state
      ) do
    {:reply, {:error, Error.new(:worker_exit, "connection is closed")}, state}
  end

  def handle_call(
        {:dispatch, module, function, args, deadline, callback_depth, caller, detached,
         pool_notify},
        _from,
        state
      ) do
    id = state.next_request_id
    trailer = call_trailer(deadline, callback_depth)
    frame = [Protocol.frame_tag(:call), id, module, function, args | trailer]

    case send_frame(state, frame) do
      :ok ->
        monitor_ref = unless detached, do: Process.monitor(caller)

        entry = %{
          caller: caller,
          monitor_ref: monitor_ref,
          cancelled: false,
          pool_notify: pool_notify
        }

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
       in_flight_callbacks: map_size(state.callback_tasks),
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

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_callback_id(state, ref) do
      {:ok, callback_id} ->
        # The callback task crashed instead of returning normally (which
        # always happens via the `{ref, result}` clause below) — report
        # it as a terminal CALLBACK_ERROR instead of leaving the caller
        # hanging forever.
        error_map = %{
          "kind" => "remote",
          "message" => "callback handler crashed: #{inspect(reason)}",
          "details" => %{},
          "remote" => %{"language" => "elixir"}
        }

        _ = send_frame(state, [Protocol.frame_tag(:callback_error), callback_id, error_map])
        {:noreply, %{state | callback_tasks: Map.delete(state.callback_tasks, callback_id)}}

      :error ->
        handle_owner_down(ref, pid, state)
    end
  end

  def handle_info({ref, task_result}, state) when is_reference(ref) do
    case find_callback_id(state, ref) do
      {:ok, callback_id} ->
        Process.demonitor(ref, [:flush])
        frame = callback_result_frame(callback_id, task_result)
        _ = send_frame(state, frame)
        {:noreply, %{state | callback_tasks: Map.delete(state.callback_tasks, callback_id)}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_owner_down(ref, _pid, state) do
    pending =
      Enum.reduce(state.pending, state.pending, fn
        {id, %{monitor_ref: ^ref} = entry}, acc ->
          _ = send_frame(state, [Protocol.frame_tag(:cancel), id])
          Map.put(acc, id, %{entry | cancelled: true})

        _, acc ->
          acc
      end)

    {:noreply, %{state | pending: pending}}
  end

  defp find_callback_id(state, ref) do
    Enum.find_value(state.callback_tasks, :error, fn {callback_id, task_ref} ->
      if task_ref == ref, do: {:ok, callback_id}
    end)
  end

  defp callback_result_frame(callback_id, {:ok, value}),
    do: [Protocol.frame_tag(:callback_return), callback_id, value]

  defp callback_result_frame(callback_id, {:error, error_map}),
    do: [Protocol.frame_tag(:callback_error), callback_id, error_map]

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
      {:ok, {:callback, fields}} -> handle_callback(fields, state)
      {:ok, {:message, [target_pid, value]}} -> handle_message(target_pid, value, state)
      {:ok, {other, _fields}} -> unsupported_frame(state, other)
      {:error, reason} -> fail_all(state, :protocol, "invalid envelope: #{inspect(reason)}")
    end
  end

  defp handle_callback([callback_id, module_str, function_str, args], state),
    do: handle_callback(callback_id, module_str, function_str, args, 1, state)

  defp handle_callback([callback_id, module_str, function_str, args, depth], state),
    do: handle_callback(callback_id, module_str, function_str, args, depth, state)

  defp handle_callback(callback_id, module_str, function_str, args, depth, state) do
    cond do
      depth > state.limits.max_callback_depth ->
        reject_callback(state, callback_id, :overload, "max_callback_depth exceeded")

      map_size(state.callback_tasks) >= state.limits.max_in_flight_callbacks ->
        reject_callback(state, callback_id, :overload, "max_in_flight_callbacks exceeded")

      true ->
        case resolve_callback_target(module_str, function_str, length(args), state) do
          {:ok, module, function} ->
            task =
              Task.Supervisor.async_nolink(state.callback_sup, fn ->
                Process.put(:portals_callback_depth, depth)
                run_callback(module, function, args)
              end)

            callback_tasks = Map.put(state.callback_tasks, callback_id, task.ref)
            {:noreply, %{state | callback_tasks: callback_tasks}}

          {:error, reason} ->
            reject_callback(state, callback_id, :protocol, inspect(reason))
        end
    end
  end

  defp reject_callback(state, callback_id, kind, message) do
    error_map = %{"kind" => Atom.to_string(kind), "message" => message, "details" => %{}}
    _ = send_frame(state, [Protocol.frame_tag(:callback_error), callback_id, error_map])
    {:noreply, state}
  end

  defp resolve_callback_target(module_str, function_str, arity, state) do
    with {:ok, module} <- safe_existing_atom(module_str),
         {:ok, function} <- safe_existing_atom(function_str),
         :ok <- check_allowlist(state.callback_allowlist, module, function, arity) do
      {:ok, module, function}
    end
  end

  defp safe_existing_atom(text) do
    {:ok, String.to_existing_atom(text)}
  rescue
    ArgumentError -> {:error, {:unsafe_atom, text}}
  end

  defp check_allowlist(nil, _module, _function, _arity), do: :ok

  defp check_allowlist(allowlist, module, function, arity) do
    if {module, function, arity} in allowlist do
      :ok
    else
      {:error, :not_allowlisted}
    end
  end

  defp run_callback(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    exception ->
      {:error,
       %{
         "kind" => "remote",
         "message" => Exception.message(exception),
         "details" => %{},
         "remote" => %{"language" => "elixir", "exception_type" => inspect(exception.__struct__)},
         "stacktrace" => Enum.map(__STACKTRACE__, &Exception.format_stacktrace_entry/1)
       }}
  end

  defp handle_message(target_pid, value, state) when is_pid(target_pid) do
    send(target_pid, envelope_message(state.message_envelope, value))
    {:noreply, state}
  end

  defp handle_message(_target, _value, state), do: {:noreply, state}

  defp envelope_message(:raw, value), do: value
  defp envelope_message(:wrapped, value), do: {:portals_message, self(), value}

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
        notify_pool(entry)
        {:noreply, %{state | pending: pending}}
    end
  end

  defp fail_all(state, kind, message) do
    error = Error.new(kind, message)

    Enum.each(state.pending, fn {id, entry} ->
      if entry.monitor_ref, do: Process.demonitor(entry.monitor_ref, [:flush])
      send(entry.caller, {:portals_result, self(), id, {:error, error}})
      notify_pool(entry)
    end)

    {:noreply, %{state | pending: %{}, status: :closed}}
  end

  defp notify_pool(%{pool_notify: nil}), do: :ok

  defp notify_pool(%{pool_notify: pool}),
    do: GenServer.cast(pool, {:worker_request_completed, self()})

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

  defp call_trailer(deadline, 0), do: opt_deadline(deadline)
  defp call_trailer(deadline, depth) when depth > 0, do: [deadline, depth]

  defp opt_deadline(nil), do: []
  defp opt_deadline(ms), do: [ms]

  defp transport_module(:unix), do: Portals.Transport.Unix
  defp transport_module(:stdio), do: Portals.Transport.Stdio
end
