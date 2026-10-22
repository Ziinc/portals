# One call at a time from the BEAM to Python and back: Portals over each
# codec and transport, zerorpc and ErlPort, on the same handlers.
#
#     mix run rpc.exs
alias Bench.Payloads

started = Bench.Config.start_all(Bench.Targets.rpc())
workloads = [{"small: add(1, 2)", :add} | Payloads.echo_specs()]

try do
  Benchee.run(
    for {name, target, handle} <- started, into: %{} do
      # Each library's payloads are prebuilt; the input picks one.
      payloads =
        Map.new(Payloads.echo_specs(), fn {_, spec} ->
          {spec, Payloads.build(spec, target.wrap_bytes)}
        end)

      {name,
       fn
         :add -> target.call.(handle, "add", [1, 2])
         spec -> target.call.(handle, "echo", [Map.fetch!(payloads, spec)])
       end}
    end,
    Bench.Config.benchee(inputs: workloads, title: "RPC round trip")
  )
after
  Bench.Config.stop_all(started)
end
