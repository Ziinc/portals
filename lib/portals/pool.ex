defmodule Portals.Pool do
  @moduledoc """
  A supervised, load-balanced set of workers running the same command
  (FR-3). Maintains `size` base workers plus up to `max_overflow`
  temporary overflow workers, created on demand and retired as soon as
  they go idle.

  Workers are not checked out exclusively: each worker can serve many
  concurrent in-flight calls (bounded by its own SDK-advertised
  `max_concurrency`), so "checkout" here means *selecting* a worker with
  spare capacity via least-in-flight scheduling (round-robin among ties),
  not reserving it. When every worker (base and overflow) is already at
  capacity and `max_overflow` is exhausted, new calls block for up to
  `checkout_timeout` before failing with `%Portals.Error{kind:
  :checkout_timeout}`. Execution timeout (the `:timeout` given to
  `call/5`/`async/5`) only starts once a worker is actually selected and
  the call is dispatched to it — it is completely independent of how
  long checkout itself took.
  """

  use GenServer

  alias Portals.{Connection, Error, Request}

  defstruct [
    :name,
    :worker_opts,
    :size,
    :max_overflow,
    :checkout_timeout,
    :supervisor,
    workers: %{},
    order: [],
    waiting: :queue.new()
  ]

  @type start_opts :: [
          command: binary,
          args: [binary],
          size: pos_integer,
          max_overflow: non_neg_integer,
          checkout_timeout: timeout,
          name: GenServer.name()
        ]

  @default_max_concurrency 16

  # -- Public API ---------------------------------------------------------

  @spec start_link(start_opts) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if name = opts[:name], do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec stop(GenServer.server(), timeout) :: :ok
  def stop(pool, deadline_ms \\ 5_000) do
    GenServer.stop(pool, :normal, deadline_ms + 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec call(GenServer.server(), binary, binary, list, keyword) ::
          {:ok, term} | {:error, Error.t()}
  def call(pool, module, function, args, opts \\ []) do
    with {:ok, request} <- async(pool, module, function, args, opts) do
      Connection.await(request, Keyword.get(opts, :timeout, 5_000))
    end
  end

  @spec call!(GenServer.server(), binary, binary, list, keyword) :: term
  def call!(pool, module, function, args, opts \\ []) do
    case call(pool, module, function, args, opts) do
      {:ok, value} -> value
      {:error, error} -> raise Portals.CallError, error: error
    end
  end

  @spec async(GenServer.server(), binary, binary, list, keyword) ::
          {:ok, Request.t()} | {:error, Error.t()}
  def async(pool, module, function, args, opts \\ []) do
    checkout_timeout = Keyword.get(opts, :checkout_timeout)
    caller = self()

    GenServer.call(
      pool,
      {:dispatch, module, function, args, Keyword.put(opts, :caller, caller)},
      checkout_timeout_budget(checkout_timeout)
    )
  end

  @spec await(Request.t(), timeout) :: {:ok, term} | {:error, Error.t()}
  def await(request, timeout \\ 5_000), do: Connection.await(request, timeout)

  @spec cancel(Request.t()) :: :ok
  def cancel(request), do: Connection.cancel(request)

  @spec health(GenServer.server()) :: map
  def health(pool), do: GenServer.call(pool, :health)

  defp checkout_timeout_budget(nil), do: :infinity
  defp checkout_timeout_budget(ms), do: ms + 1_000

  # -- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    worker_opts =
      Keyword.take(opts, [
        :command,
        :args,
        :transport,
        :limits,
        :env,
        :cd,
        :connect_timeout,
        :handshake_timeout,
        :callback_allowlist,
        :message_envelope
      ])

    state = %__MODULE__{
      name: Keyword.get(opts, :name),
      worker_opts: worker_opts,
      size: Keyword.fetch!(opts, :size),
      max_overflow: Keyword.get(opts, :max_overflow, 0),
      checkout_timeout: Keyword.get(opts, :checkout_timeout, 5_000),
      supervisor: supervisor
    }

    case start_base_workers(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:dispatch, module, function, args, opts}, from, state) do
    case select_worker(state) do
      {:ok, conn, state} ->
        {:reply, dispatch_to(conn, module, function, args, opts, state), state}

      :overflow_needed ->
        case start_overflow_worker(state) do
          {:ok, conn, state} ->
            {:reply, dispatch_to(conn, module, function, args, opts, state), state}

          {:error, _reason} ->
            enqueue_waiter(from, module, function, args, opts, state)
        end

      :saturated ->
        enqueue_waiter(from, module, function, args, opts, state)
    end
  end

  def handle_call(:health, _from, state) do
    workers =
      Map.new(state.workers, fn {conn, w} ->
        {conn, %{kind: w.kind, in_flight: w.in_flight, max_concurrency: w.max_concurrency}}
      end)

    {:reply,
     %{
       size: state.size,
       max_overflow: state.max_overflow,
       worker_count: map_size(state.workers),
       waiting: :queue.len(state.waiting),
       workers: workers
     }, state}
  end

  @impl true
  def handle_cast({:worker_request_completed, conn}, state) do
    state =
      case Map.fetch(state.workers, conn) do
        {:ok, worker} ->
          worker = %{worker | in_flight: max(worker.in_flight - 1, 0)}
          %{state | workers: Map.put(state.workers, conn, worker)}

        :error ->
          state
      end

    state =
      if Map.has_key?(state.workers, conn) and worker_closed?(conn) do
        evict_worker(conn, state)
      else
        maybe_retire_idle_overflow(conn, state)
      end

    {:noreply, service_waiting(state)}
  end

  @impl true
  def handle_info({:checkout_timeout, ref}, state) do
    items = :queue.to_list(state.waiting)

    case Enum.find(items, fn {r, _, _, _, _, _} -> r == ref end) do
      nil ->
        # Already serviced before the timer fired; nothing to do.
        {:noreply, state}

      {^ref, from, _m, _f, _a, _o} ->
        GenServer.reply(from, {:error, Error.new(:checkout_timeout, "no worker available")})

        waiting =
          items |> Enum.reject(fn {r, _, _, _, _, _} -> r == ref end) |> :queue.from_list()

        {:noreply, %{state | waiting: waiting}}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.fetch(state.workers, pid) do
      :error ->
        {:noreply, state}

      {:ok, _worker} ->
        {:noreply, service_waiting(evict_worker(pid, state, reason))}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # -- Worker startup -------------------------------------------------------

  defp start_base_workers(state) do
    Enum.reduce_while(1..state.size, {:ok, state}, fn _i, {:ok, acc} ->
      case start_worker(acc, :base) do
        {:ok, _conn, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_overflow_worker(state) do
    current_overflow = Enum.count(state.workers, fn {_conn, w} -> w.kind == :overflow end)

    if current_overflow < state.max_overflow do
      start_worker(state, :overflow)
    else
      {:error, :max_overflow_reached}
    end
  end

  defp start_worker(state, kind) do
    spec = %{
      id: make_ref(),
      start: {Connection, :start_link, [state.worker_opts]},
      restart: :temporary
    }

    with {:ok, conn} <- DynamicSupervisor.start_child(state.supervisor, spec) do
      Process.monitor(conn)
      max_concurrency = advertised_concurrency(conn)
      worker = %{kind: kind, in_flight: 0, max_concurrency: max_concurrency}

      state = %{
        state
        | workers: Map.put(state.workers, conn, worker),
          order: state.order ++ [conn]
      }

      {:ok, conn, state}
    end
  end

  defp advertised_concurrency(conn) do
    case Connection.health(conn) do
      %{worker_info: %Portals.Handshake.Hello{max_concurrency: n}} when is_integer(n) and n > 0 ->
        n

      _ ->
        @default_max_concurrency
    end
  end

  defp replace_base_worker(state, reason) do
    case start_worker(state, :base) do
      {:ok, _conn, state} ->
        state

      {:error, _start_reason} ->
        require Logger
        Logger.error("Portals.Pool: failed to replace crashed base worker (#{inspect(reason)})")
        state
    end
  end

  defp worker_closed?(conn) do
    Connection.health(conn).status == :closed
  catch
    :exit, _ -> true
  end

  defp evict_worker(conn, state, reason \\ :worker_closed) do
    case Map.pop(state.workers, conn) do
      {nil, _workers} ->
        state

      {worker, workers} ->
        state = %{state | workers: workers, order: List.delete(state.order, conn)}
        DynamicSupervisor.terminate_child(state.supervisor, conn)
        if worker.kind == :base, do: replace_base_worker(state, reason), else: state
    end
  end

  # -- Scheduling -----------------------------------------------------------

  defp select_worker(state) do
    candidates =
      state.order
      |> Enum.map(&{&1, Map.fetch!(state.workers, &1)})
      |> Enum.filter(fn {_conn, w} -> w.in_flight < w.max_concurrency end)

    case candidates do
      [] ->
        if map_size(state.workers) - state.size < state.max_overflow,
          do: :overflow_needed,
          else: :saturated

      _ ->
        min_in_flight = candidates |> Enum.map(fn {_c, w} -> w.in_flight end) |> Enum.min()
        tied = Enum.filter(candidates, fn {_c, w} -> w.in_flight == min_in_flight end)
        {conn, _w} = Enum.min_by(tied, fn {c, _w} -> index_in_order(state.order, c) end)
        {:ok, conn, bump_in_flight(state, conn)}
    end
  end

  defp index_in_order(order, conn), do: Enum.find_index(order, &(&1 == conn))

  defp bump_in_flight(state, conn) do
    worker = Map.fetch!(state.workers, conn)
    %{state | workers: Map.put(state.workers, conn, %{worker | in_flight: worker.in_flight + 1})}
  end

  defp dispatch_to(conn, module, function, args, opts, state) do
    opts = Keyword.put(opts, :pool_notify, self_pool_ref(state))
    Connection.async(conn, module, function, args, opts)
  end

  defp self_pool_ref(_state), do: self()

  defp enqueue_waiter(from, module, function, args, opts, state) do
    ref = make_ref()
    Process.send_after(self(), {:checkout_timeout, ref}, state.checkout_timeout)
    waiting = :queue.in({ref, from, module, function, args, opts}, state.waiting)
    {:noreply, %{state | waiting: waiting}}
  end

  defp service_waiting(state) do
    case :queue.out(state.waiting) do
      {:empty, _} ->
        state

      {{:value, {_ref, from, module, function, args, opts} = item}, rest} ->
        case select_worker(state) do
          {:ok, conn, state} ->
            GenServer.reply(from, dispatch_to(conn, module, function, args, opts, state))
            service_waiting(%{state | waiting: rest})

          :overflow_needed ->
            case start_overflow_worker(state) do
              {:ok, conn, state} ->
                GenServer.reply(from, dispatch_to(conn, module, function, args, opts, state))
                service_waiting(%{state | waiting: rest})

              {:error, _reason} ->
                # Can't service yet; leave the queue as-is (still holding `item`).
                _ = item
                state
            end

          :saturated ->
            state
        end
    end
  end

  # Overflow workers are retired the instant they go idle (in_flight == 0
  # and no waiters left to serve), per FR-3's idle/check-in policy.
  defp maybe_retire_idle_overflow(conn, state) do
    with {:ok, %{kind: :overflow, in_flight: 0}} <- Map.fetch(state.workers, conn),
         0 <- :queue.len(state.waiting) do
      DynamicSupervisor.terminate_child(state.supervisor, conn)
      %{state | workers: Map.delete(state.workers, conn), order: List.delete(state.order, conn)}
    else
      _ -> state
    end
  end
end
