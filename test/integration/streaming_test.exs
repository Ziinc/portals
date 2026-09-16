defmodule Portals.Integration.StreamingTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Phase 6 exit criteria, exercised against a real Python worker:

    * neither peer can exceed the documented byte or frame allowance;
    * half-close and cancellation are independent and release all state;
    * long-lived streams do not exhaust unary capacity.
  """

  @moduletag :integration

  @worker_script Path.expand("../../sdk/python/tests/fixtures/run_worker.py", __DIR__)

  defp python! do
    System.find_executable("python3") || System.find_executable("python") ||
      raise "python3 not available; required for Portals integration tests"
  end

  defp start_worker(opts \\ []) do
    {:ok, conn} = Portals.start_worker([command: python!(), args: [@worker_script]] ++ opts)

    on_exit(fn -> Portals.stop_worker(conn, 500) end)
    conn
  end

  defp limits(overrides) do
    Map.merge(Portals.Protocol.default_limits(), Map.new(overrides))
  end

  # Drain whatever the connection has already delivered for `stream`
  # without waiting, returning the chunks (and crediting them back).
  defp drain_available(stream, acc \\ []) do
    case Portals.Stream.recv(stream, 0) do
      {:ok, chunk} -> drain_available(stream, [chunk | acc])
      _ -> Enum.reverse(acc)
    end
  end

  describe "bidirectional streaming" do
    setup do
      {:ok, conn: start_worker()}
    end

    test "echoes chunks in both directions and terminates with a RETURN", %{conn: conn} do
      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])

      assert :ok = Portals.Stream.send(stream, "a")
      assert {:ok, "a"} = Portals.Stream.recv(stream, 5_000)

      assert :ok = Portals.Stream.send(stream, "b")
      assert {:ok, "b"} = Portals.Stream.recv(stream, 5_000)

      :ok = Portals.Stream.half_close(stream)
      assert :half_closed = Portals.Stream.recv(stream, 5_000)
      assert {:ok, 2} = Portals.Stream.await(stream, 5_000)
    end

    test "the Enumerable APIs cover both directions", %{conn: conn} do
      {:ok, out} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])
      assert :ok = Portals.Stream.send_enumerable(out, ["x", "y", "z"])

      assert ["x", "y", "z"] = out |> Portals.Stream.to_enumerable(5_000) |> Enum.to_list()
      assert {:ok, 3} = Portals.Stream.await(out, 5_000)
    end

    test "a worker-produced stream is consumed lazily as an Enumerable", %{conn: conn} do
      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "produce_stream", [5, 16])
      :ok = Portals.Stream.half_close(stream)

      chunks = stream |> Portals.Stream.to_enumerable(5_000) |> Enum.to_list()

      assert length(chunks) == 5
      assert Enum.all?(chunks, &(byte_size(&1) == 16))
      assert {:ok, 5} = Portals.Stream.await(stream, 5_000)
    end

    test "opening more streams than the worker advertised is a bounded overload error" do
      conn = start_worker(env: [{"PORTALS_MAX_STREAMS", "2"}])

      streams =
        for _ <- 1..2 do
          {:ok, stream} = Portals.open_stream(conn, "bench_worker", "hold_stream", [2_000])
          stream
        end

      assert {:error, %Portals.Error{kind: :overload}} =
               Portals.open_stream(conn, "bench_worker", "hold_stream", [10])

      Enum.each(streams, &Portals.Stream.cancel/1)
    end
  end

  describe "byte and frame allowances" do
    test "the worker cannot send more bytes than the BEAM credited it" do
      window = 8_192
      conn = start_worker(limits: limits(max_stream_byte_credit: window))

      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "produce_stream", [200, 1024])
      :ok = Portals.Stream.half_close(stream)

      # Deliberately do not consume for a while: the worker's producer must
      # block on its credit window instead of flooding the BEAM.
      Process.sleep(300)
      chunks = drain_available(stream)
      received = Enum.reduce(chunks, 0, fn chunk, acc -> acc + byte_size(chunk) end)

      assert received > 0
      assert received <= window

      # Once consumption resumes, credit flows again and the stream completes.
      rest = stream |> Portals.Stream.to_enumerable(5_000) |> Enum.to_list()
      assert length(chunks) + length(rest) == 200
      assert {:ok, 200} = Portals.Stream.await(stream, 5_000)
    end

    test "a flood of tiny frames is bounded by the queued-frame limit, not the byte window" do
      max_frames = 4
      conn = start_worker(limits: limits(max_queued_stream_frames: max_frames))

      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "produce_stream", [500, 1])
      :ok = Portals.Stream.half_close(stream)

      Process.sleep(300)
      chunks = drain_available(stream)

      # Plenty of byte credit remained; only the frame cap held the
      # producer back.
      assert length(chunks) <= max_frames

      rest = stream |> Portals.Stream.to_enumerable(5_000) |> Enum.to_list()
      assert length(chunks) + length(rest) == 500
    end

    test "the BEAM cannot send more bytes than the worker credited it" do
      window = 8_192
      conn = start_worker(limits: limits(max_stream_byte_credit: window))

      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "never_consume", [500])

      # The worker never consumes, so after roughly one window of bytes the
      # producing process blocks rather than buffering in the BEAM.
      sent =
        Enum.reduce_while(1..1_000, 0, fn _, acc ->
          case Portals.Stream.send(stream, :binary.copy("x", 1024), 200) do
            :ok -> {:cont, acc + 1024}
            {:error, _} -> {:halt, acc}
          end
        end)

      # The producer was blocked well before it could push 1 MiB, and the
      # bytes it did push fit inside one credit window.
      assert sent < 1_000 * 1024
      assert sent <= window

      Portals.Stream.cancel(stream)
    end
  end

  describe "half-close and cancellation release all state" do
    setup do
      {:ok, conn: start_worker()}
    end

    test "each direction half-closes independently", %{conn: conn} do
      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "half_close_then_drain", [])

      # The worker half-closed immediately; the BEAM's own direction is
      # still fully usable.
      assert :half_closed = Portals.Stream.recv(stream, 5_000)

      assert :ok = Portals.Stream.send(stream, "still-open-1")
      assert :ok = Portals.Stream.send(stream, "still-open-2")
      :ok = Portals.Stream.half_close(stream)

      assert {:ok, 2} = Portals.Stream.await(stream, 5_000)
      assert Portals.health(conn).open_streams == 0
    end

    test "sending after a local half-close is refused", %{conn: conn} do
      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])
      :ok = Portals.Stream.half_close(stream)
      # The cast must be processed before the next send is evaluated.
      _ = Portals.health(conn)

      assert {:error, %Portals.Error{kind: :protocol}} = Portals.Stream.send(stream, "late")
      Portals.Stream.cancel(stream)
    end

    test "cancelling releases every piece of connection state", %{conn: conn} do
      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "hold_stream", [5_000])
      assert Portals.health(conn).open_streams == 1

      :ok = Portals.Stream.cancel(stream)
      assert Portals.health(conn).open_streams == 0

      # The worker released its side too, so its stream capacity is back.
      assert {:ok, _} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])

      # Unary calls are unaffected by the cancelled stream.
      assert {:ok, 3} = Portals.call(conn, "bench_worker", "add", [1, 2])
    end

    test "a dead stream owner releases the stream", %{conn: conn} do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, _stream} = Portals.open_stream(conn, "bench_worker", "hold_stream", [5_000])
          send(parent, :opened)
          receive do: (:stop -> :ok)
        end)

      assert_receive :opened, 5_000
      assert Portals.health(conn).open_streams == 1

      ref = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

      # Give the connection a chance to process the monitor message.
      _ = Portals.health(conn)
      assert Portals.health(conn).open_streams == 0
    end

    test "a worker crash terminates every open stream exactly once", %{conn: conn} do
      {:ok, stream} = Portals.open_stream(conn, "bench_worker", "hold_stream", [5_000])
      {:ok, _} = Portals.async(conn, "bench_worker", "crash_process", [])

      assert {:closed, {:error, %Portals.Error{}}} = Portals.Stream.recv(stream, 5_000)
      assert {:error, :timeout} = Portals.Stream.recv(stream, 100)
    end
  end

  describe "unary/stream fairness" do
    test "long-lived streams do not exhaust unary capacity" do
      # Two unary slots and four stream slots: every stream slot is held
      # by a long-lived stream while unary calls keep flowing.
      conn = start_worker(env: [{"PORTALS_MAX_CONCURRENCY", "2"}, {"PORTALS_MAX_STREAMS", "4"}])

      streams =
        for _ <- 1..4 do
          {:ok, stream} = Portals.open_stream(conn, "bench_worker", "hold_stream", [3_000])
          stream
        end

      assert Portals.health(conn).open_streams == 4

      results =
        for i <- 1..20 do
          Portals.call(conn, "bench_worker", "add", [i, 1], timeout: 5_000)
        end

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert results == Enum.map(1..20, &{:ok, &1 + 1})

      Enum.each(streams, &Portals.Stream.cancel/1)
    end

    test "unary in-flight capacity is bounded independently of streams" do
      conn = start_worker(limits: limits(max_in_flight_requests: 2))

      held =
        for _ <- 1..2 do
          {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [400])
          request
        end

      assert {:error, %Portals.Error{kind: :overload}} =
               Portals.async(conn, "bench_worker", "echo", ["x"])

      # Stream capacity is a separate budget and is still available.
      assert {:ok, stream} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])

      Enum.each(held, &Portals.await(&1, 5_000))
      Portals.Stream.cancel(stream)
    end
  end
end
