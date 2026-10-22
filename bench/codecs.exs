# BEAM-side codec cost: encode + decode one RETURN frame carrying each
# workload, in the BEAM process alone (no worker, no I/O).
#
#     mix run codecs.exs
alias Bench.Payloads

limits = Portals.Protocol.default_limits()
frame = fn payload -> [Portals.Protocol.frame_tag(:return), 1, payload] end

codecs = [
  {"Portals MessagePack", &%Portals.Codec.Bin{data: &1},
   fn term ->
     {:ok, bytes} = Portals.Codec.MessagePack.encode(term, limits)
     {:ok, _, _} = Portals.Codec.MessagePack.decode(bytes, limits)
     bytes
   end},
  {"Portals ETF", &%Portals.Codec.Bin{data: &1},
   fn term ->
     {:ok, bytes} = Portals.Codec.ETF.encode(term, limits)
     {:ok, _, _} = Portals.Codec.ETF.decode(bytes, limits)
     bytes
   end},
  {"term_to_binary (raw ETF)", & &1,
   fn term ->
     bytes = :erlang.term_to_binary(term)
     _ = :erlang.binary_to_term(bytes, [:safe])
     bytes
   end},
  {"Msgpax", &Msgpax.Bin.new/1,
   fn term ->
     bytes = Msgpax.pack!(term, iodata: false)
     _ = Msgpax.unpack!(bytes)
     bytes
   end},
  {"Jason (JSON, bytes as base64)", &Base.encode64/1,
   fn term ->
     bytes = Jason.encode!(term)
     _ = Jason.decode!(bytes)
     bytes
   end}
]

workloads = [{"small: [1, 2]", :small} | Payloads.echo_specs()]

build = fn
  :small, _wrap -> [1, 2]
  spec, wrap -> Payloads.build(spec, wrap)
end

IO.puts("\nEncoded frame size (bytes)\n")

for {codec, wrap, round_trip} <- codecs do
  sizes =
    for {name, spec} <- workloads do
      "#{name}: #{byte_size(round_trip.(frame.(build.(spec, wrap))))}"
    end

  IO.puts("  #{codec}: " <> Enum.join(sizes, ", "))
end

# Each codec's frames are prebuilt per workload; the input picks one.
prebuilt =
  for {codec, wrap, _} <- codecs, {_, spec} <- workloads, into: %{} do
    {{codec, spec}, frame.(build.(spec, wrap))}
  end

Benchee.run(
  for {codec, _wrap, round_trip} <- codecs, into: %{} do
    {codec, fn spec -> round_trip.(Map.fetch!(prebuilt, {codec, spec})) end}
  end,
  Bench.Config.benchee(inputs: workloads, memory_time: 1, title: "BEAM codecs: encode + decode")
)
