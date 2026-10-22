# Raw transport round trips: a frame to a Python echo server and back, no
# codec and no RPC (see lib/bench/transports.ex).
#
#     mix run transports.exs
started = Bench.Config.start_all(Bench.Transports.all())

frames = for {name, size} <- Bench.Payloads.frame_sizes(), do: {name, :binary.copy(<<7>>, size)}

try do
  Benchee.run(
    for {name, transport, handle} <- started, into: %{} do
      {name,
       {fn frame -> transport.round_trip.(handle, frame) end,
        before_scenario: fn frame ->
          :ok = transport.claim.(handle)
          frame
        end,
        after_scenario: fn _ -> :ok = transport.release.(handle) end}}
    end,
    Bench.Config.benchee(inputs: frames, title: "Raw transport round trip")
  )
after
  Bench.Config.stop_all(started)
end
