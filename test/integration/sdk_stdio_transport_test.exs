defmodule Portals.Integration.SdkStdioTransportTest do
  @moduledoc """
  The framed stdio fallback transport (protocol/v1.md section 1) works
  identically for the Ruby and Node SDKs, matching
  `Portals.Integration.StdioTransportTest`'s coverage of the Python SDK.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  @workers [
    {"ruby", "ruby", "sdk/ruby/test/fixtures/run_worker_stdio.rb"},
    {"node", "node", "sdk/node/test/fixtures/run_worker_stdio.js"}
  ]

  for {name, runtime, path} <- @workers do
    @runtime runtime
    @script Path.expand("../../" <> path, __DIR__)

    describe "#{name} over framed stdio" do
      setup do
        executable =
          System.find_executable(@runtime) ||
            raise "#{@runtime} not available; required for Portals integration tests"

        {:ok, conn} =
          Portals.start_worker(command: executable, args: [@script], transport: :stdio)

        on_exit(fn -> Portals.stop_worker(conn, 500) end)
        {:ok, conn: conn}
      end

      test "completes calls end to end", %{conn: conn} do
        assert {:ok, "hello"} = Portals.call(conn, "bench_worker", "echo", ["hello"])
        assert {:ok, 7} = Portals.call(conn, "bench_worker", "add", [3, 4])
      end

      test "malformed input is rejected without raising", %{conn: conn} do
        {:ok, request} = Portals.async(conn, "bench_worker", "sleep_ms", [2_000])

        state = :sys.get_state(conn)
        send(conn, {state.socket, {:data, <<0xFF, 0xFF, 0xFF, 0xFF>>}})

        assert {:error, %Portals.Error{kind: :protocol}} = Portals.await(request, 3_000)
      end
    end
  end
end
