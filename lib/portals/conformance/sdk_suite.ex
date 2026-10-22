defmodule Portals.Conformance.SDKSuite do
  @moduledoc """
  The protocol conformance suite every worker SDK must pass.

  `Portals.Conformance.Runner` checks a codec directly. A foreign SDK cannot
  be handed to it as a module, so this suite drives it over a
  language-neutral bridge instead: every SDK ships a `conformance_worker`
  fixture whose `echo_term` round-trips a term through the SDK's own codec
  and whose `decode_reason` classifies raw bytes with the codec the worker
  is running. The golden vectors (`protocol/vectors/golden.exs`) and the
  codec's malformed fixtures (`protocol/malformed/`) are replayed against
  it from the same source of truth the Elixir codecs are checked against,
  so every SDK classifies every fixture identically. Use the suite once per
  codec.

      defmodule PortalsRuby.ConformanceTest do
        use Portals.Conformance.SDKSuite,
          language: "ruby",
          worker: Portals.Ruby.worker_opts(script: "priv/ruby/test/fixtures/run_worker.rb"),
          stdio_worker:
            Portals.Ruby.worker_opts(script: "priv/ruby/test/fixtures/run_worker_stdio.rb"),
          bad_version_worker:
            Portals.Ruby.worker_opts(
              script: "priv/ruby/test/fixtures/run_worker.rb",
              env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
            )
      end

  ## Options

    * `:language` (required) — used in test names.
    * `:worker` (required) — `Portals.start_worker/1` options for a worker
      that serves the `conformance_worker` and `bench_worker` fixtures over
      the default Unix-socket transport.
    * `:stdio_worker` (required) — the same, for a worker using the framed
      stdio fallback transport. The suite adds `transport: :stdio`.
    * `:bad_version_worker` (required) — a worker that advertises protocol
      version 999 in its `HELLO`.
    * `:codec` — `:etf` (the default) or `:msgpack`; added to every worker's
      options.
    * `:moduletag` — extra module tags for every test in the suite, e.g.
      `[runtime: :deno]`.

  The suite also asserts that the SDK reports the same version as the
  `portals` application, since every SDK is released in lockstep with it.
  """

  # How every SDK without a BEAM atom table must classify each malformed
  # fixture. The unknown-atom fixtures are the one documented divergence
  # from the BEAM: protocol/v1.md 5.3 explicitly permits SDKs to decode atom
  # text as a native symbol, since the atom-table exhaustion risk is
  # BEAM-specific.
  @etf_expected_reasons %{
    "etf_empty_binary" => "truncated",
    "etf_missing_version_byte" => "invalid_encoding",
    "etf_truncated_list" => "truncated",
    "etf_truncated_binary" => "truncated",
    "etf_unknown_tag" => "invalid_encoding",
    "etf_oversized_list_length" => "max_length_exceeded",
    "etf_unknown_atom" => "ok",
    "etf_trailing_bytes" => "trailing_bytes",
    "etf_binary_not_utf8" => "invalid_encoding",
    "etf_bit_binary" => "invalid_encoding",
    "etf_nesting_too_deep" => "max_depth_exceeded",
    "etf_truncated_stream_data_chunk" => "truncated"
  }

  @msgpack_expected_reasons %{
    "truncated_fixarray" => "truncated",
    "truncated_str8_header" => "truncated",
    "truncated_str8_body" => "truncated",
    "unknown_leading_byte" => "invalid_encoding",
    "oversized_array_length" => "max_length_exceeded",
    "unsafe_atom_extension" => "ok",
    "invalid_extension_type" => "invalid_extension",
    "bad_tuple_ext_trailing_bytes" => "invalid_extension",
    "empty_binary" => "truncated",
    "truncated_stream_data_chunk" => "truncated",
    "truncated_credit_frame" => "truncated"
  }

  @doc "The `decode_reason` every SDK must report for each of `codec`'s malformed fixtures."
  @spec expected_reasons(:etf | :msgpack) :: %{String.t() => String.t()}
  def expected_reasons(:etf), do: @etf_expected_reasons
  def expected_reasons(:msgpack), do: @msgpack_expected_reasons

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      @moduletag :integration
      # Extra module tags (e.g. `moduletag: [runtime: :deno]`), applied here
      # because they must be set before the suite's tests are defined.
      @moduletag Keyword.get(opts, :moduletag, [])

      alias Portals.Conformance.Runner

      @codec Keyword.get(opts, :codec, :etf)
      @language "#{Keyword.fetch!(opts, :language)} (#{@codec})"
      @worker_opts Keyword.fetch!(opts, :worker) ++ [codec: @codec]
      @stdio_worker_opts Keyword.fetch!(opts, :stdio_worker) ++ [codec: @codec]
      @bad_version_worker_opts Keyword.fetch!(opts, :bad_version_worker) ++ [codec: @codec]

      defp start_conformance_worker(opts) do
        {:ok, conn} = Portals.start_worker(opts)
        on_exit(fn -> Portals.stop_worker(conn, 500) end)
        conn
      end

      test "#{@language}: every golden vector round-trips through the SDK's own codec" do
        conn = start_conformance_worker(@worker_opts)

        failures =
          for {vector_name, term} <- Runner.golden_vectors(),
              result =
                Portals.call(conn, "conformance_worker", "echo_term", [term], timeout: 10_000),
              result != {:ok, term} do
            {vector_name, term, result}
          end

        assert failures == [],
               "#{@language} failed golden vectors: #{inspect(failures, limit: 5)}"
      end

      test "#{@language}: every malformed fixture is classified like every other SDK" do
        conn = start_conformance_worker(@worker_opts)

        for {fixture_name, bytes, _expected_beam_reason} <- Runner.malformed_fixtures(@codec) do
          assert {:ok, reason} =
                   Portals.call(
                     conn,
                     "conformance_worker",
                     "decode_reason",
                     [%Portals.Codec.Bin{data: bytes}],
                     timeout: 10_000
                   )

          assert reason ==
                   Map.fetch!(
                     Portals.Conformance.SDKSuite.expected_reasons(@codec),
                     fixture_name
                   ),
                 "#{@language} classified #{fixture_name} as #{inspect(reason)}"
        end

        # Rejecting malformed input never takes the connection down.
        assert Portals.health(conn).status == :ready
      end

      test "#{@language}: reports the protocol version and release the BEAM expects" do
        conn = start_conformance_worker(@worker_opts)

        assert {:ok, info} = Portals.call(conn, "conformance_worker", "version_info", [])
        assert info["protocol_version"] == Portals.Protocol.version()
        # Every SDK ships in lockstep with core `portals`.
        assert info["sdk_version"] == to_string(Application.spec(:portals, :vsn))
        assert is_binary(info["language"])

        # The HELLO the BEAM accepted carries the same version plus a runtime
        # identifier, and a non-zero stream capacity.
        worker_info = Portals.health(conn).worker_info
        assert worker_info.protocol_version == Portals.Protocol.version()
        assert is_binary(worker_info.runtime) and worker_info.runtime != ""
        assert worker_info.max_concurrency > 0
        assert worker_info.max_streams > 0
      end

      # The failed handshake is logged by design; keep it out of test output.
      @tag capture_log: true
      test "#{@language}: a mismatched HELLO fails startup deterministically" do
        # start_link: the failing worker's exit signal would kill this test.
        Process.flag(:trap_exit, true)

        assert {:error, {:handshake_failed, {:protocol_version_mismatch, expected, 999}}} =
                 Portals.start_worker(@bad_version_worker_opts)

        assert expected == Portals.Protocol.version()
      end

      describe "#{@language} over framed stdio" do
        setup do
          {:ok, conn: start_conformance_worker(@stdio_worker_opts ++ [transport: :stdio])}
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
end
