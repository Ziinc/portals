defmodule Portals.Conformance.SdkConformanceTest do
  @moduledoc """
  Phase 7 exit criteria: Python, Ruby and Node.js pass the *identical*
  black-box conformance suite, and their version diagnostics agree.

  `Portals.Conformance.Runner` is codec-agnostic and already exercises the
  Elixir reference codec directly. A foreign SDK cannot be handed to it as
  a module, so it is exercised over the language-neutral bridge the runner's
  docs describe: each SDK ships a `conformance_worker` whose `echo_term`
  round-trips a term through its own codec and whose `decode_reason`
  classifies raw bytes. Both fixture files
  (`protocol/vectors/golden.exs`, `protocol/malformed/fixtures.exs`) are
  replayed against every SDK, from the same source of truth the Elixir
  codec is checked against.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  alias Portals.Conformance.Runner

  @sdks [
    {"python", "python3", "sdk/python/tests/fixtures/run_worker.py"},
    {"ruby", "ruby", "sdk/ruby/test/fixtures/run_worker.rb"},
    {"node", "node", "sdk/node/test/fixtures/run_worker.js"}
  ]

  @bad_version_workers [
    {"python", "python3", "sdk/python/tests/fixtures/run_worker_bad_version.py", []},
    {"ruby", "ruby", "sdk/ruby/test/fixtures/run_worker.rb",
     [{"PORTALS_PROTOCOL_VERSION", "999"}]},
    {"node", "node", "sdk/node/test/fixtures/run_worker.js",
     [{"PORTALS_PROTOCOL_VERSION", "999"}]}
  ]

  # How every SDK without a BEAM atom table must classify each malformed
  # fixture. `unsafe_atom_extension` is the one documented divergence:
  # protocol/v1.md 5.3 explicitly permits Python/Ruby/Node to decode atom
  # text as a native symbol, since the atom-table exhaustion risk is
  # BEAM-specific. Every other fixture must be rejected with the same
  # reason by all three.
  @expected_reasons %{
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

  defp script(path), do: Path.expand("../../" <> path, __DIR__)

  defp executable!(runtime) do
    System.find_executable(runtime) ||
      raise "#{runtime} not available; required for Portals conformance tests"
  end

  defp start(runtime, path, env \\ []) do
    Portals.start_worker(
      command: executable!(runtime),
      args: [script(path)],
      env: env
    )
  end

  for {name, runtime, path} <- @sdks do
    @name name
    @runtime runtime
    @path path

    test "#{name}: every golden vector round-trips through the SDK's own codec" do
      {:ok, conn} = start(@runtime, @path)
      on_exit(fn -> Portals.stop_worker(conn, 500) end)

      failures =
        for {vector_name, term} <- Runner.golden_vectors(),
            result =
              Portals.call(conn, "conformance_worker", "echo_term", [term], timeout: 10_000),
            result != {:ok, term} do
          {vector_name, term, result}
        end

      assert failures == [], "#{@name} failed golden vectors: #{inspect(failures, limit: 5)}"
    end

    test "#{name}: every malformed fixture is classified identically" do
      {:ok, conn} = start(@runtime, @path)
      on_exit(fn -> Portals.stop_worker(conn, 500) end)

      for {fixture_name, bytes, _expected_beam_reason} <- Runner.malformed_fixtures() do
        assert {:ok, reason} =
                 Portals.call(
                   conn,
                   "conformance_worker",
                   "decode_reason",
                   [%Portals.Codec.Bin{data: bytes}],
                   timeout: 10_000
                 )

        assert reason == Map.fetch!(@expected_reasons, fixture_name),
               "#{@name} classified #{fixture_name} as #{inspect(reason)}"
      end

      # Rejecting malformed input never takes the connection down.
      assert Portals.health(conn).status == :ready
    end

    test "#{name}: reports the same protocol version as the BEAM" do
      {:ok, conn} = start(@runtime, @path)
      on_exit(fn -> Portals.stop_worker(conn, 500) end)

      assert {:ok, info} = Portals.call(conn, "conformance_worker", "version_info", [])
      assert info["protocol_version"] == Portals.Protocol.version()
      assert info["sdk_version"] == "1.0.0"
      assert is_binary(info["language"])

      # The HELLO the BEAM accepted carries the same version plus a runtime
      # identifier, and a non-zero stream capacity for every bundled SDK.
      worker_info = Portals.health(conn).worker_info
      assert worker_info.protocol_version == Portals.Protocol.version()
      assert is_binary(worker_info.runtime) and worker_info.runtime != ""
      assert worker_info.max_concurrency > 0
      assert worker_info.max_streams > 0
    end
  end

  describe "protocol version mismatch" do
    for {name, runtime, path, env} <- @bad_version_workers do
      @runtime runtime
      @path path
      @env env

      test "#{name}: a mismatched HELLO fails startup deterministically" do
        # Identical, deterministic diagnostics for every bundled SDK.
        assert {:error, {:handshake_failed, {:protocol_version_mismatch, expected, 999}}} =
                 start(@runtime, @path, @env)

        assert expected == Portals.Protocol.version()
      end
    end
  end

  test "all three SDKs agree on every malformed classification" do
    conns =
      for {name, runtime, path} <- @sdks do
        {:ok, conn} = start(runtime, path)
        on_exit(fn -> Portals.stop_worker(conn, 500) end)
        {name, conn}
      end

    for {fixture_name, bytes, _} <- Runner.malformed_fixtures() do
      reasons =
        for {name, conn} <- conns do
          {:ok, reason} =
            Portals.call(conn, "conformance_worker", "decode_reason", [
              %Portals.Codec.Bin{data: bytes}
            ])

          {name, reason}
        end

      assert Enum.uniq(Enum.map(reasons, &elem(&1, 1))) |> length() == 1,
             "SDKs disagree on #{fixture_name}: #{inspect(reasons)}"
    end
  end
end
