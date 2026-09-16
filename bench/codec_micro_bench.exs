# Isolated codec microbenchmarks (Phase 8): pure encode/decode cost with
# no transport, worker, or protocol-state-machine overhead involved.
#
#   mix run bench/codec_micro_bench.exs
alias Portals.Protocol
alias Portals.Codec.MessagePack

limits = Protocol.default_limits()

small_term = ["hello", 42, %{"ok" => true}]
medium_term = for i <- 1..50, do: %{"id" => i, "name" => "worker-#{i}", "ok" => rem(i, 2) == 0}
large_term = for i <- 1..2000, do: [i, i * 2, "row-#{i}"]

inputs = %{
  "small (3 fields)" => small_term,
  "medium (50 maps)" => medium_term,
  "large (2000 rows)" => large_term
}

Benchee.run(
  %{
    "MessagePack encode" => fn term -> MessagePack.encode(term, limits) end,
    "ETFBench encode" => fn term -> Portals.Codec.ETFBench.encode(term, limits) end
  },
  inputs: inputs,
  time: 2,
  warmup: 1,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/codec_encode.json"}
  ]
)

encoded_inputs =
  Map.new(inputs, fn {name, term} ->
    {:ok, mp} = MessagePack.encode(term, limits)
    {:ok, etf} = Portals.Codec.ETFBench.encode(term, limits)
    {name, %{mp: mp, etf: etf}}
  end)

Benchee.run(
  %{
    "MessagePack decode" => fn %{mp: bytes} -> MessagePack.decode(bytes, limits) end,
    "ETFBench decode" => fn %{etf: bytes} -> Portals.Codec.ETFBench.decode(bytes, limits) end
  },
  inputs: encoded_inputs,
  time: 2,
  warmup: 1,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/codec_decode.json"}
  ]
)
