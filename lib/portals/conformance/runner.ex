defmodule Portals.Conformance.Runner do
  @moduledoc """
  Black-box protocol conformance runner (FR-7 / Phase 1 exit criteria).

  Tests a codec purely through the `Portals.Codec` behaviour — encode a
  frame envelope, decode it back, and check the fixed-shape golden vectors
  and malformed fixtures shared by every SDK. A worker SDK's own codec can
  be exercised by this runner over a language-neutral bridge (e.g. driving
  the SDK's binary through stdin/stdout) as long as that bridge exposes
  the same `encode/2` and `decode/2` contract; no Elixir-internal
  knowledge of the codec under test is required.

  Vectors live in `protocol/vectors/golden.exs` and are shared by both
  codecs; malformed fixtures are per codec, in
  `protocol/malformed/etf_fixtures.exs` and `protocol/malformed/fixtures.exs`
  (MessagePack). All are plain data files (no macros, no codec-specific
  syntax) so every SDK's test suite can load and replay them independently.
  """

  alias Portals.Protocol

  @type codec_module :: module
  @type failure :: %{name: binary, reason: term}
  @type result :: %{passed: non_neg_integer, failed: [failure]}

  @golden_vectors_path Path.expand("../../../protocol/vectors/golden.exs", __DIR__)
  @malformed_fixtures_paths %{
    etf: Path.expand("../../../protocol/malformed/etf_fixtures.exs", __DIR__),
    msgpack: Path.expand("../../../protocol/malformed/fixtures.exs", __DIR__)
  }

  @spec golden_vectors() :: [{binary, list}]
  def golden_vectors, do: eval_fixture_file(@golden_vectors_path)

  @doc """
  The malformed fixtures for `codec` (`:etf` or `:msgpack`), as
  `{name, bytes, expected_beam_reason}`. An expected reason of `:ok` marks
  bytes the BEAM accepts but SDKs must reject.
  """
  @spec malformed_fixtures(:etf | :msgpack) :: [{binary, binary, atom}]
  def malformed_fixtures(codec),
    do: eval_fixture_file(Map.fetch!(@malformed_fixtures_paths, codec))

  @doc "Run every golden vector and malformed fixture against `codec` (a module implementing `Portals.Codec`)."
  @spec run(codec_module, Protocol.limits()) :: result
  def run(codec, limits \\ Protocol.default_limits()) do
    fixtures = malformed_fixtures(codec_name(codec))
    golden_failures = Enum.flat_map(golden_vectors(), &check_golden_vector(&1, codec, limits))

    malformed_failures = Enum.flat_map(fixtures, &check_malformed_fixture(&1, codec, limits))

    failures = golden_failures ++ malformed_failures
    total = length(golden_vectors()) + length(fixtures)

    %{passed: total - length(failures), failed: failures}
  end

  defp check_golden_vector({name, term}, codec, limits) do
    with {:ok, encoded} <- codec.encode(term, limits),
         {:ok, decoded, <<>>} <- codec.decode(encoded, limits) do
      if terms_equivalent?(decoded, term) do
        []
      else
        [%{name: name, reason: {:round_trip_mismatch, expected: term, actual: decoded}}]
      end
    else
      {:ok, _decoded, extra} -> [%{name: name, reason: {:trailing_bytes_after_decode, extra}}]
      {:error, reason} -> [%{name: name, reason: {:codec_error, reason}}]
    end
  end

  defp codec_name(Portals.Codec.ETF), do: :etf
  defp codec_name(Portals.Codec.MessagePack), do: :msgpack

  defp check_malformed_fixture({name, bytes, :ok}, codec, limits) do
    case codec.decode(bytes, limits) do
      {:ok, _decoded, _rest} -> []
      {:error, reason} -> [%{name: name, reason: {:rejected_valid_term, reason}}]
    end
  end

  defp check_malformed_fixture({name, bytes, expected_reason}, codec, limits) do
    case codec.decode(bytes, limits) do
      {:error, reason} ->
        if reason_matches?(reason, expected_reason) do
          []
        else
          [
            %{
              name: name,
              reason: {:wrong_rejection_reason, expected: expected_reason, actual: reason}
            }
          ]
        end

      {:ok, decoded, _rest} ->
        [%{name: name, reason: {:accepted_malformed_input, decoded}}]
    end
  end

  defp reason_matches?(reason, expected) when is_atom(reason), do: reason == expected
  defp reason_matches?({reason, _detail}, expected) when is_atom(reason), do: reason == expected
  defp reason_matches?(_reason, _expected), do: false

  # Floats decode exactly (float64 round trip); everything else must be `===`.
  defp terms_equivalent?(a, a), do: true
  defp terms_equivalent?([], []), do: true

  defp terms_equivalent?([ah | at], [bh | bt]),
    do: terms_equivalent?(ah, bh) and terms_equivalent?(at, bt)

  defp terms_equivalent?(a, b) when is_map(a) and is_map(b) do
    map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and terms_equivalent?(v, Map.fetch!(b, k)) end)
  end

  defp terms_equivalent?(a, b) when is_tuple(a) and is_tuple(b) do
    terms_equivalent?(Tuple.to_list(a), Tuple.to_list(b))
  end

  defp terms_equivalent?(_a, _b), do: false

  defp eval_fixture_file(path) do
    {result, _bindings} = Code.eval_file(path)
    result
  end
end
