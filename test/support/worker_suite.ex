defmodule Portals.Fixtures.WorkerSuite do
  @moduledoc """
  The shared integration suite every bundled worker SDK must pass.

  Phase 7's exit criterion is that Python, Ruby and Node.js are held to the
  *same* black-box expectations, so the assertions live here once and each
  SDK's test module supplies only the command that launches its worker:

      use Portals.Fixtures.WorkerSuite,
        runtime: "ruby",
        script: "sdk/ruby/test/fixtures/run_worker.rb"

  Nothing in here knows anything about the worker's implementation
  language — it drives `Portals.Connection`/`Portals.Pool` exactly as an
  application would.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      @moduletag :integration

      @runtime Keyword.fetch!(opts, :runtime)
      @script Path.expand("../../" <> Keyword.fetch!(opts, :script), __DIR__)
      @extra_args Keyword.get(opts, :extra_args, [])

      defp executable! do
        System.find_executable(@runtime) ||
          raise "#{@runtime} not available; required for Portals integration tests"
      end

      defp start_worker(opts \\ []) do
        {:ok, conn} =
          Portals.start_worker([command: executable!(), args: @extra_args ++ [@script]] ++ opts)

        on_exit(fn -> Portals.stop_worker(conn, 500) end)
        conn
      end

      defp limits(overrides) do
        Map.merge(Portals.Protocol.default_limits(), Map.new(overrides))
      end

      defp drain_available(stream, acc \\ []) do
        case Portals.Stream.recv(stream, 0) do
          {:ok, chunk} -> drain_available(stream, [chunk | acc])
          _ -> Enum.reverse(acc)
        end
      end

      describe "unary calls" do
        setup do
          {:ok, conn: start_worker()}
        end

        test "calls an arbitrary module/function and gets the result back", %{conn: conn} do
          assert {:ok, "hello"} = Portals.call(conn, "bench_worker", "echo", ["hello"])
          assert {:ok, 3} = Portals.call(conn, "bench_worker", "add", [1, 2])
        end

        test "call! returns the value directly", %{conn: conn} do
          assert Portals.call!(conn, "bench_worker", "echo", [42]) == 42
        end

        test "call! raises Portals.CallError on a remote exception", %{conn: conn} do
          assert_raise Portals.CallError, fn ->
            Portals.call!(conn, "bench_worker", "raise_error", ["boom"])
          end
        end

        test "a remote exception is reported as a structured %Portals.Error{}", %{conn: conn} do
          assert {:error, %Portals.Error{kind: :remote, message: "boom"} = error} =
                   Portals.call(conn, "bench_worker", "raise_error", ["boom"])

          assert is_binary(error.remote["language"])
          assert is_binary(error.remote["exception_type"])
          assert is_list(error.stacktrace)
        end

        test "an unknown module or function is a structured error, not a crash", %{conn: conn} do
          assert {:error, %Portals.Error{kind: :remote}} =
                   Portals.call(conn, "bench_worker", "no_such_function", [])

          assert {:error, %Portals.Error{kind: :remote}} =
                   Portals.call(conn, "no_such_module", "nope", [])

          assert Portals.health(conn).status == :ready
        end

        test "many concurrent in-flight calls complete out of order", %{conn: conn} do
          requests =
            for i <- 1..64 do
              delay = rem(64 - i, 5) * 2
              {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [delay])
              {i, request}
            end

          results = for {_i, request} <- requests, do: Portals.await(request, 10_000)

          assert Enum.all?(results, &match?({:ok, _}, &1))
        end

        test "the reader is independent of handler execution", %{conn: conn} do
          # A long call is in flight and occupies a handler; short calls
          # dispatched afterwards must still complete well before it.
          {:ok, slow} = Portals.async(conn, "bench_worker", "sleep_ms", [1_500])

          for i <- 1..10 do
            assert {:ok, ^i} = Portals.call(conn, "bench_worker", "add", [i, 0], timeout: 2_000)
          end

          assert {:ok, 1_500} = Portals.await(slow, 5_000)
        end

        test "every pending caller receives a terminal error after the worker crashes", %{
          conn: conn
        } do
          requests =
            for _ <- 1..5 do
              {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [2_000])
              request
            end

          {:ok, _crash_request} = Portals.async(conn, "bench_worker", "crash_process", [])

          for request <- requests do
            assert {:error, %Portals.Error{kind: :worker_exit}} = Portals.await(request, 5_000)
          end
        end

        test "cancel is cooperative, idempotent, and races safely with the terminal response", %{
          conn: conn
        } do
          {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [50])
          Portals.cancel(request)
          Portals.cancel(request)

          assert {:ok, 50} = Portals.await(request, 2_000)
          assert Portals.health(conn).status == :ready
        end

        test "a CANCEL raises the worker's cooperative cancellation flag", %{conn: conn} do
          {:ok, request} = Portals.async(conn, "bench_worker", "cancellable", [5_000])
          Process.sleep(50)
          Portals.cancel(request)

          assert {:ok, "cancelled"} = Portals.await(request, 3_000)
          assert Portals.health(conn).status == :ready
        end

        test "a deadline is delivered to the worker", %{conn: conn} do
          assert {:ok, 4_000} =
                   Portals.call(conn, "bench_worker", "deadline_probe", [], deadline_ms: 4_000)
        end

        test "an async caller that exits does not crash the connection", %{conn: conn} do
          parent = self()

          {caller_pid, caller_ref} =
            spawn_monitor(fn ->
              {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [1_000])
              send(parent, {:started, request.id})
              Process.sleep(:infinity)
            end)

          assert_receive {:started, _request_id}, 2_000
          Process.exit(caller_pid, :kill)
          assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :killed}, 2_000

          Process.sleep(100)
          assert Portals.health(conn).status == :ready
          assert {:ok, "still alive"} = Portals.call(conn, "bench_worker", "echo", ["still alive"])
        end

        test "receiving malformed bytes only terminates that connection", %{conn: conn} do
          {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [2_000])

          state = :sys.get_state(conn)
          send(conn, {:tcp, state.socket, <<0xFF, 0xFF, 0xFF, 0xFF>>})

          assert {:error, %Portals.Error{kind: :protocol}} = Portals.await(request, 3_000)
          assert Portals.health(conn).status == :closed
        end
      end

      describe "the value model survives a round trip through the worker" do
        setup do
          {:ok, conn: start_worker()}
        end

        test "primitives, binaries, tuples, atoms, bigints and improper lists", %{conn: conn} do
          terms = [
            nil,
            true,
            [1, 2, 3, -1],
            0.5,
            "text",
            %Portals.Codec.Bin{data: <<0, 1, 2, 255>>},
            %{"nested" => %{"ok" => true}},
            {:ok, "value", 3},
            :some_atom,
            123_456_789_012_345_678_901_234_567_890,
            [1, 2 | :tail]
          ]

          for term <- terms do
            assert {:ok, echoed} = Portals.call(conn, "bench_worker", "echo_term", [term])
            assert echoed == term, "#{inspect(term)} did not survive the round trip"
          end
        end

        test "a PID round-trips opaquely and can be used as a MESSAGE target", %{conn: conn} do
          assert {:ok, pid} = Portals.call(conn, "bench_worker", "echo_term", [self()])
          assert pid == self()
        end
      end

      describe "callbacks and PID messaging" do
        setup do
          {:ok, conn: start_worker()}
        end

        test "a handler can call back into the BEAM and get a result", %{conn: conn} do
          assert {:ok, 84} = Portals.call(conn, "bench_worker", "double_via_callback", [42])
        end

        test "a failing BEAM callback target is reported back as a remote error", %{conn: conn} do
          assert {:error, %Portals.Error{kind: :remote} = error} =
                   Portals.call(conn, "bench_worker", "raise_callback_error", [])

          assert error.message =~ "callback target exploded"
        end

        test "the worker can message the calling process directly", %{conn: conn} do
          assert {:ok, "sent"} =
                   Portals.call(conn, "bench_worker", "message_to_caller", [
                     self(),
                     %{"progress" => 0.5}
                   ])

          assert_receive {:portals_message, ^conn, %{"progress" => 0.5}}, 2_000
        end

        test "an in-flight call still resolves while unrelated callbacks are handled", %{
          conn: conn
        } do
          {:ok, sleeper} = Portals.async(conn, "bench_worker", "sleep_ms", [200])
          assert {:ok, 20} = Portals.call(conn, "bench_worker", "double_via_callback", [10])
          assert {:ok, 200} = Portals.await(sleeper, 3_000)
        end

        test "a callback never blocks the reader: many run concurrently", %{conn: conn} do
          requests =
            for i <- 1..16 do
              {:ok, request} = Portals.async(conn, "bench_worker", "double_via_callback", [i])
              {i, request}
            end

          for {i, request} <- requests do
            assert {:ok, doubled} = Portals.await(request, 10_000)
            assert doubled == i * 2
          end
        end

        test "an unknown callback target is rejected without crashing the connection", %{
          conn: conn
        } do
          state = :sys.get_state(conn)

          frame = [Portals.Protocol.frame_tag(:callback), 999_999, "NoSuchModule", "nope", []]
          {:ok, bytes} = Portals.Codec.MessagePack.encode(frame, state.limits)
          send(conn, {:tcp, state.socket, bytes})

          Process.sleep(100)
          assert Portals.health(conn).status == :ready
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

        test "a worker-produced stream is consumed lazily as an Enumerable", %{conn: conn} do
          {:ok, stream} = Portals.open_stream(conn, "bench_worker", "produce_stream", [5, 16])
          :ok = Portals.Stream.half_close(stream)

          chunks = stream |> Portals.Stream.to_enumerable(5_000) |> Enum.to_list()

          assert length(chunks) == 5
          assert Enum.all?(chunks, &(byte_size(&1) == 16))
          assert {:ok, 5} = Portals.Stream.await(stream, 5_000)
        end

        test "each direction half-closes independently", %{conn: conn} do
          {:ok, stream} =
            Portals.open_stream(conn, "bench_worker", "half_close_then_drain", [])

          assert :half_closed = Portals.Stream.recv(stream, 5_000)

          assert :ok = Portals.Stream.send(stream, "still-open-1")
          assert :ok = Portals.Stream.send(stream, "still-open-2")
          :ok = Portals.Stream.half_close(stream)

          assert {:ok, 2} = Portals.Stream.await(stream, 5_000)
          assert Portals.health(conn).open_streams == 0
        end

        test "cancelling releases every piece of connection state", %{conn: conn} do
          {:ok, stream} = Portals.open_stream(conn, "bench_worker", "hold_stream", [5_000])
          assert Portals.health(conn).open_streams == 1

          :ok = Portals.Stream.cancel(stream)
          assert Portals.health(conn).open_streams == 0

          assert {:ok, _} = Portals.open_stream(conn, "bench_worker", "echo_stream", [])
          assert {:ok, 3} = Portals.call(conn, "bench_worker", "add", [1, 2])
        end
      end

      describe "streaming allowances" do
        test "the worker cannot send more bytes than the BEAM credited it" do
          window = 8_192
          conn = start_worker(limits: limits(max_stream_byte_credit: window))

          {:ok, stream} = Portals.open_stream(conn, "bench_worker", "produce_stream", [200, 1024])
          :ok = Portals.Stream.half_close(stream)

          Process.sleep(300)
          chunks = drain_available(stream)
          received = Enum.reduce(chunks, 0, fn chunk, acc -> acc + byte_size(chunk) end)

          assert received > 0
          assert received <= window

          rest = stream |> Portals.Stream.to_enumerable(10_000) |> Enum.to_list()
          assert length(chunks) + length(rest) == 200
          assert {:ok, 200} = Portals.Stream.await(stream, 5_000)
        end

        test "a flood of tiny frames is bounded by the queued-frame limit" do
          max_frames = 4
          conn = start_worker(limits: limits(max_queued_stream_frames: max_frames))

          {:ok, stream} = Portals.open_stream(conn, "bench_worker", "produce_stream", [500, 1])
          :ok = Portals.Stream.half_close(stream)

          Process.sleep(300)
          chunks = drain_available(stream)

          assert length(chunks) <= max_frames

          rest = stream |> Portals.Stream.to_enumerable(10_000) |> Enum.to_list()
          assert length(chunks) + length(rest) == 500
        end

        test "the BEAM cannot send more bytes than the worker credited it" do
          window = 8_192
          conn = start_worker(limits: limits(max_stream_byte_credit: window))

          {:ok, stream} = Portals.open_stream(conn, "bench_worker", "never_consume", [500])

          sent =
            Enum.reduce_while(1..1_000, 0, fn _, acc ->
              case Portals.Stream.send(stream, :binary.copy("x", 1024), 200) do
                :ok -> {:cont, acc + 1024}
                {:error, _} -> {:halt, acc}
              end
            end)

          assert sent < 1_000 * 1024
          assert sent <= window

          Portals.Stream.cancel(stream)
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

        test "long-lived streams do not exhaust unary capacity" do
          conn =
            start_worker(env: [{"PORTALS_MAX_CONCURRENCY", "2"}, {"PORTALS_MAX_STREAMS", "4"}])

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

          assert results == Enum.map(1..20, &{:ok, &1 + 1})

          Enum.each(streams, &Portals.Stream.cancel/1)
        end
      end

      describe "pooling" do
        test "a pool of these workers round-robins calls" do
          {:ok, pool} =
            Portals.start_pool(
              command: executable!(),
              args: @extra_args ++ [@script],
              size: 2,
              max_overflow: 0
            )

          on_exit(fn -> Portals.Pool.stop(pool) end)

          results = for i <- 1..20, do: Portals.Pool.call(pool, "bench_worker", "add", [i, 1])
          assert results == Enum.map(1..20, &{:ok, &1 + 1})
        end
      end
    end
  end
end
