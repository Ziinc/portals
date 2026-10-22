defmodule Bench.Payloads do
  @moduledoc """
  The workloads, described once and built per target, since each library
  spells "raw bytes" differently (`%Portals.Codec.Bin{}`, `%Msgpax.Bin{}`,
  a plain binary for ETF and ErlPort, base64 for JSON).
  """

  @doc "Echo workloads, in report order: `{name, spec}`."
  def echo_specs do
    [
      {"1 KiB text", {:text, 1024}},
      {"64 KiB bytes", {:bytes, 65_536}},
      {"1 MiB bytes", {:bytes, 1_048_576}},
      {"1,000 integers", {:ints, 1000}},
      {"100 records", {:records, 100}}
    ]
  end

  @doc "Raw transport frame sizes: `{name, bytes}`."
  def frame_sizes do
    [{"64 B", 64}, {"4 KiB", 4096}, {"64 KiB", 65_536}, {"1 MiB", 1_048_576}]
  end

  @doc "Builds `spec`, passing raw bytes through `wrap_bytes`."
  def build(spec, wrap_bytes \\ & &1)

  def build({:text, n}, _wrap) do
    "The quick brown fox jumps over the lazy dog. "
    |> String.duplicate(div(n, 45) + 1)
    |> binary_part(0, n)
  end

  def build({:bytes, n}, wrap), do: wrap.(bytes(n))
  def build({:ints, n}, _wrap), do: Enum.map(1..n, &(&1 * 7919))

  def build({:records, n}, _wrap) do
    for i <- 1..n do
      %{
        "id" => i,
        "name" => "user-#{i}",
        "email" => "user#{i}@example.com",
        "score" => i * 1.5,
        "active" => rem(i, 2) == 0,
        "tags" => ["alpha", "beta"]
      }
    end
  end

  # Deterministic, incompressible bytes.
  defp bytes(n) do
    :rand.seed(:exsss, {1, 2, 3})
    :rand.bytes(n)
  end
end
