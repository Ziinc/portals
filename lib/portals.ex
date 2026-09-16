defmodule Portals do
  @moduledoc """
  Public API for invoking functions in a supervised external-language
  worker (FR-2).

  Two entry points exist:

    * `start_worker/1` (Phase 3) — one directly managed `Portals.Connection`.
      The functions below (`call/5`, `async/5`, `await/2`, `cancel/2`,
      `health/1`) operate on it.
    * `start_pool/1` (Phase 4) — a supervised, load-balanced
      `Portals.Pool` of many workers with overflow and checkout. Use
      `Portals.Pool.call/5` etc. (same shapes as the functions below) once
      you have a pool.

  ## Example

      {:ok, conn} =
        Portals.start_worker(command: "python3", args: ["priv/python_worker.py"])

      {:ok, "hello"} = Portals.call(conn, "bench_worker", "echo", ["hello"])

      {:ok, pool} =
        Portals.start_pool(command: "python3", args: ["priv/python_worker.py"], size: 4)

      {:ok, "hello"} = Portals.Pool.call(pool, "bench_worker", "echo", ["hello"])
  """

  alias Portals.{Connection, Error, Pool, Request}

  @doc "Start and hand-shake with one worker. See `Portals.Connection.start_link/1` for options."
  @spec start_worker(Connection.start_opts()) :: {:ok, pid} | {:error, term}
  def start_worker(opts), do: Connection.start_link(opts)

  @doc "Start a supervised pool of workers. See `Portals.Pool.start_link/1` for options."
  @spec start_pool(Pool.start_opts()) :: {:ok, pid} | {:error, term}
  def start_pool(opts), do: Pool.start_link(opts)

  @doc "Stop a worker, sending `SHUTDOWN` and waiting up to `deadline_ms` before force-killing it."
  @spec stop_worker(GenServer.server(), timeout) :: :ok
  def stop_worker(conn, deadline_ms \\ 5_000), do: Connection.stop(conn, deadline_ms)

  @doc "Invoke `module`/`function` with `args` and block for the result."
  @spec call(GenServer.server(), binary, binary, list, keyword) ::
          {:ok, term} | {:error, Error.t()}
  def call(conn, module, function, args, opts \\ []),
    do: Connection.call(conn, module, function, args, opts)

  @doc "Like `call/5`, but returns the value directly and raises `Portals.CallError` on failure."
  @spec call!(GenServer.server(), binary, binary, list, keyword) :: term
  def call!(conn, module, function, args, opts \\ []),
    do: Connection.call!(conn, module, function, args, opts)

  @doc "Invoke `module`/`function` with `args` without blocking; await the result with `await/2`."
  @spec async(GenServer.server(), binary, binary, list, keyword) ::
          {:ok, Request.t()} | {:error, Error.t()}
  def async(conn, module, function, args, opts \\ []),
    do: Connection.async(conn, module, function, args, opts)

  @doc "Block for the result of a request started with `async/5`."
  @spec await(Request.t(), timeout) :: {:ok, term} | {:error, Error.t()}
  def await(request, timeout \\ 5_000), do: Connection.await(request, timeout)

  @doc "Cooperatively cancel a request started with `async/5`. Idempotent."
  @spec cancel(Request.t()) :: :ok
  def cancel(request), do: Connection.cancel(request)

  @doc """
  Open a bidirectional stream against `module`/`function` (FR-5).

  Returns a `%Portals.Stream{}` handle; see `Portals.Stream` for the
  explicit send/half-close/receive API and the `Enumerable` API.

      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])
      :ok = Portals.Stream.send_enumerable(stream, ["a", "b"])
      ["a", "b"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
  """
  @spec open_stream(GenServer.server(), binary, binary, list, keyword) ::
          {:ok, Portals.Stream.t()} | {:error, Error.t()}
  def open_stream(conn, module, function, args \\ [], opts \\ []),
    do: Connection.open_stream(conn, module, function, args, opts)

  @doc "A snapshot of one worker's status and in-flight request count."
  @spec health(GenServer.server()) :: map
  def health(conn), do: Connection.health(conn)
end
