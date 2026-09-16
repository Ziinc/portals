defmodule Portals.Stream do
  @moduledoc """
  A handle on one bidirectional stream, plus the demand/credit and
  terminal-state machine behind it (FR-5, Phase 6).

  A stream is opened by the BEAM with `Portals.open_stream/5`, which
  dispatches an ordinary `CALL` frame and then uses that call's
  `request_id` as the stream's `stream_id` (see `protocol/v1.md` §9).
  Both directions then carry `STREAM_DATA`, and either peer may
  `HALF_CLOSE` its own sending direction independently. The call's
  `RETURN`/`ERROR` is the stream's terminal frame.

  Backpressure is an encoded-byte credit window, independent in each
  direction, plus a hard cap on the number of queued (sent but not yet
  consumed) frames so a flood of tiny frames cannot evade the byte
  window. Credits are charged against the *complete* encoded frame size,
  including the 4-byte length prefix.

  ## Explicit stream-handle API

      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])
      :ok = Portals.Stream.send(stream, "chunk-1")
      :ok = Portals.Stream.half_close(stream)
      {:ok, "chunk-1"} = Portals.Stream.recv(stream)
      :half_closed = Portals.Stream.recv(stream)
      {:ok, "done"} = Portals.Stream.await(stream)

  ## Enumerable API

      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])
      :ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
      chunks = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()

  `Portals.Stream.send/3` blocks the calling process while the peer's
  credit window is exhausted, so a slow consumer applies backpressure to
  the producer instead of growing BEAM memory.
  """

  alias Portals.Error

  @enforce_keys [:connection, :id]
  defstruct [:connection, :id]

  @type t :: %__MODULE__{connection: pid, id: non_neg_integer}

  @type recv_result ::
          {:ok, term}
          | :half_closed
          | {:closed, {:ok, term} | {:error, Error.t()}}
          | {:error, :timeout}

  # -- Handle API -------------------------------------------------------

  @doc """
  Send one chunk on the outbound direction, blocking until the peer has
  granted enough byte credit (and frame allowance) to accept it.

  Returns `{:error, %Portals.Error{}}` if the outbound direction is
  already half-closed, the stream was cancelled or terminated, or the
  chunk cannot be encoded within the connection's frame limits.

  Note that a `send/3` that gives up on `timeout` only stops *waiting*:
  the chunk stays queued behind the credit window and is still delivered
  if credit arrives later. Cancel the stream if you need it not to be.
  """
  @spec send(t, term, timeout) :: :ok | {:error, Error.t()}
  def send(%__MODULE__{connection: conn, id: id}, chunk, timeout \\ 5_000) do
    GenServer.call(conn, {:stream_send, id, chunk}, timeout)
  catch
    :exit, _ -> {:error, Error.new(:worker_exit, "connection is closed")}
  end

  @doc """
  Close *only* the local sending direction. The peer may keep sending
  until it half-closes its own direction. Idempotent.
  """
  @spec half_close(t) :: :ok
  def half_close(%__MODULE__{connection: conn, id: id}) do
    GenServer.cast(conn, {:stream_half_close, id})
  end

  @doc """
  Cancel the stream in both directions, sending `CANCEL` and releasing
  every piece of local state for it. Idempotent.
  """
  @spec cancel(t) :: :ok
  def cancel(%__MODULE__{connection: conn, id: id}) do
    GenServer.cast(conn, {:stream_cancel, id})
  end

  @doc """
  Receive the next inbound event for this stream in the owning process.

  Consuming a chunk is what releases credit back to the peer, so a
  process that stops calling `recv/2` stops the peer's producer.
  """
  @spec recv(t, timeout) :: recv_result
  def recv(%__MODULE__{connection: conn, id: id}, timeout \\ 5_000) do
    receive do
      {:portals_stream, ^conn, ^id, {:data, chunk, frame_bytes}} ->
        GenServer.cast(conn, {:stream_consumed, id, frame_bytes, 1})
        {:ok, chunk}

      {:portals_stream, ^conn, ^id, :half_closed} ->
        :half_closed

      {:portals_stream, ^conn, ^id, {:closed, result}} ->
        {:closed, result}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Block for the stream's terminal `RETURN`/`ERROR`, discarding (but
  crediting) any inbound chunks still queued for the owner.
  """
  @spec await(t, timeout) :: {:ok, term} | {:error, Error.t()}
  def await(%__MODULE__{} = stream, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + normalize_timeout(timeout)
    do_await(stream, deadline)
  end

  defp do_await(stream, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case recv(stream, remaining) do
      {:closed, result} -> result
      {:error, :timeout} -> {:error, Error.new(:execution_timeout, "stream did not terminate")}
      _ -> do_await(stream, deadline)
    end
  end

  defp normalize_timeout(:infinity), do: 1_000 * 60 * 60 * 24
  defp normalize_timeout(ms) when is_integer(ms), do: ms

  @doc """
  The inbound direction as a lazy `Enumerable` of chunks. The enumeration
  halts when the peer half-closes or the stream terminates; a terminal
  `ERROR` raises `Portals.CallError`.
  """
  @spec to_enumerable(t, timeout) :: Enumerable.t()
  def to_enumerable(%__MODULE__{} = stream, timeout \\ 5_000) do
    Elixir.Stream.resource(
      fn -> stream end,
      fn stream ->
        case recv(stream, timeout) do
          {:ok, chunk} -> {[chunk], stream}
          :half_closed -> {:halt, stream}
          {:closed, {:ok, _value}} -> {:halt, stream}
          {:closed, {:error, error}} -> raise Portals.CallError, error: error
          {:error, :timeout} -> raise Portals.CallError, error: timeout_error()
        end
      end,
      fn _stream -> :ok end
    )
  end

  defp timeout_error, do: Error.new(:execution_timeout, "stream receive timed out")

  @doc """
  Outbound `Enumerable` API: push every element of `enumerable` onto the
  stream, respecting credit, then half-close the outbound direction.

  Pass `half_close: false` to keep the outbound direction open.
  """
  @spec send_enumerable(t, Enumerable.t(), keyword) :: :ok | {:error, Error.t()}
  def send_enumerable(%__MODULE__{} = stream, enumerable, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    close? = Keyword.get(opts, :half_close, true)

    result =
      Enum.reduce_while(enumerable, :ok, fn chunk, :ok ->
        case __MODULE__.send(stream, chunk, timeout) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      :ok ->
        if close?, do: half_close(stream)
        :ok

      error ->
        error
    end
  end

  defmodule State do
    @moduledoc """
    The per-stream credit and terminal-state machine, owned functionally
    by `Portals.Connection` (like the pending-request table) rather than
    by a process of its own.

    Two completely independent windows:

      * **send window** — `send_credit` bytes the peer has granted us and
        `send_frames` frames we have sent that the peer has not yet
        acknowledged, capped by `max_frames`;
      * **receive window** — `recv_credit` bytes we have granted the peer
        and `recv_frames` frames it has sent that our owner has not yet
        consumed, capped by `max_frames`.

    Every byte figure is the *complete* encoded frame size, including the
    4-byte length prefix.
    """

    @enforce_keys [:id, :owner, :max_credit, :max_frames]
    defstruct [
      :id,
      :owner,
      :owner_ref,
      :max_credit,
      :max_frames,
      send_credit: 0,
      send_frames: 0,
      recv_credit: 0,
      recv_frames: 0,
      recv_bytes: 0,
      outbound: :open,
      inbound: :open,
      send_waiters: :queue.new()
    ]

    @type direction_state :: :open | :closed

    @type t :: %__MODULE__{
            id: non_neg_integer,
            owner: pid,
            owner_ref: reference | nil,
            max_credit: pos_integer,
            max_frames: pos_integer,
            send_credit: non_neg_integer,
            send_frames: non_neg_integer,
            recv_credit: non_neg_integer,
            recv_frames: non_neg_integer,
            recv_bytes: non_neg_integer,
            outbound: direction_state,
            inbound: direction_state,
            send_waiters: :queue.queue()
          }

    @doc "A fresh stream with no credit in either direction."
    @spec new(non_neg_integer, pid, keyword) :: t
    def new(id, owner, opts) do
      %__MODULE__{
        id: id,
        owner: owner,
        owner_ref: Keyword.get(opts, :owner_ref),
        max_credit: Keyword.fetch!(opts, :max_credit),
        max_frames: Keyword.fetch!(opts, :max_frames)
      }
    end

    @doc """
    The initial (or replenishing) grant this side owes the peer: the
    unused portion of our receive window. Returns `{state, bytes}`;
    `bytes` is `0` when there is nothing new to grant.
    """
    @spec grant(t) :: {t, non_neg_integer}
    def grant(%__MODULE__{} = state) do
      bytes = state.max_credit - state.recv_credit - state.recv_bytes

      if bytes > 0 do
        {%{state | recv_credit: state.recv_credit + bytes}, bytes}
      else
        {state, 0}
      end
    end

    @doc "Apply a `CREDIT` frame received from the peer."
    @spec add_send_credit(t, non_neg_integer, non_neg_integer) ::
            {:ok, t} | {:error, :credit_limit_exceeded}
    def add_send_credit(%__MODULE__{} = state, bytes, frames)
        when is_integer(bytes) and bytes >= 0 and is_integer(frames) and frames >= 0 do
      credit = state.send_credit + bytes

      if credit > state.max_credit do
        {:error, :credit_limit_exceeded}
      else
        {:ok, %{state | send_credit: credit, send_frames: max(state.send_frames - frames, 0)}}
      end
    end

    def add_send_credit(_state, _bytes, _frames), do: {:error, :credit_limit_exceeded}

    @doc """
    Charge one outbound frame of `bytes` encoded bytes against the send
    window. Never sends: the caller must only put the frame on the wire
    when this returns `{:ok, state}`.
    """
    @spec charge_send(t, pos_integer) ::
            {:ok, t} | {:error, :outbound_closed | :insufficient_credit | :frame_limit}
    def charge_send(%__MODULE__{outbound: :closed}, _bytes), do: {:error, :outbound_closed}

    def charge_send(%__MODULE__{} = state, bytes) do
      cond do
        state.send_frames >= state.max_frames ->
          {:error, :frame_limit}

        bytes > state.send_credit ->
          {:error, :insufficient_credit}

        true ->
          {:ok,
           %{state | send_credit: state.send_credit - bytes, send_frames: state.send_frames + 1}}
      end
    end

    @doc """
    Record one inbound `STREAM_DATA` frame of `bytes` encoded bytes.
    Rejects anything the peer was not entitled to send.
    """
    @spec record_inbound(t, pos_integer) ::
            {:ok, t} | {:error, :inbound_closed | :credit_exceeded | :frame_limit}
    def record_inbound(%__MODULE__{inbound: :closed}, _bytes), do: {:error, :inbound_closed}

    def record_inbound(%__MODULE__{} = state, bytes) do
      cond do
        state.recv_frames >= state.max_frames ->
          {:error, :frame_limit}

        bytes > state.recv_credit ->
          {:error, :credit_exceeded}

        true ->
          {:ok,
           %{
             state
             | recv_credit: state.recv_credit - bytes,
               recv_frames: state.recv_frames + 1,
               recv_bytes: state.recv_bytes + bytes
           }}
      end
    end

    @doc """
    The owner consumed `frames` inbound frames totalling `bytes` encoded
    bytes. Returns the replenished state and the number of bytes to grant
    back to the peer in a `CREDIT` frame.
    """
    @spec consume_inbound(t, non_neg_integer, non_neg_integer) :: {t, non_neg_integer}
    def consume_inbound(%__MODULE__{} = state, bytes, frames) do
      state = %{
        state
        | recv_frames: max(state.recv_frames - frames, 0),
          recv_bytes: max(state.recv_bytes - bytes, 0)
      }

      grant(state)
    end

    @doc "Close only this side's sending direction. Idempotent."
    @spec half_close_outbound(t) :: {:ok, t} | :already_closed
    def half_close_outbound(%__MODULE__{outbound: :closed}), do: :already_closed
    def half_close_outbound(%__MODULE__{} = state), do: {:ok, %{state | outbound: :closed}}

    @doc "Record the peer's `HALF_CLOSE` of its sending direction. Idempotent."
    @spec half_close_inbound(t) :: {:ok, t} | :already_closed
    def half_close_inbound(%__MODULE__{inbound: :closed}), do: :already_closed
    def half_close_inbound(%__MODULE__{} = state), do: {:ok, %{state | inbound: :closed}}

    @doc "True when both directions are half-closed; the terminal frame may still be outstanding."
    @spec fully_half_closed?(t) :: boolean
    def fully_half_closed?(%__MODULE__{outbound: :closed, inbound: :closed}), do: true
    def fully_half_closed?(%__MODULE__{}), do: false

    @doc "Park a blocked sender until credit arrives."
    @spec park_sender(t, term) :: t
    def park_sender(%__MODULE__{} = state, waiter),
      do: %{state | send_waiters: :queue.in(waiter, state.send_waiters)}

    @doc "Pop the next parked sender, if any."
    @spec pop_sender(t) :: {:ok, term, t} | :empty
    def pop_sender(%__MODULE__{} = state) do
      case :queue.out(state.send_waiters) do
        {{:value, waiter}, rest} -> {:ok, waiter, %{state | send_waiters: rest}}
        {:empty, _} -> :empty
      end
    end

    @doc "Every parked sender, in order, leaving the queue empty."
    @spec take_senders(t) :: {[term], t}
    def take_senders(%__MODULE__{} = state),
      do: {:queue.to_list(state.send_waiters), %{state | send_waiters: :queue.new()}}
  end
end
