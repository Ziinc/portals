# Throughput under concurrency: one batch is 1,000 `add` calls with up to
# 64 in flight. Calls per second = batches per second x 1,000.
#
#     mix run concurrency.exs
alias Bench.Targets

batch = 1_000
in_flight = 64

started =
  Bench.Config.start_all([
    {"Portals: 1 worker", Targets.portals(transport: :unix)},
    {"Portals: 1 worker, inline", Targets.portals(transport: :unix, inline: true)},
    {"Portals: pool of 4", Targets.portals(transport: :unix, size: 4)},
    {"zerorpc: 1 server", Targets.zerorpc()},
    {"ErlPort: 1 interpreter", Targets.erlport()},
    {"ErlPort: 4 interpreters", Targets.erlport(instances: 4)}
  ])

try do
  Benchee.run(
    for {name, target, handle} <- started, into: %{} do
      {name,
       fn ->
         1..batch
         |> Task.async_stream(&target.call.(handle, "add", [&1, 1]),
           max_concurrency: in_flight,
           ordered: false,
           timeout: 60_000
         )
         |> Stream.run()
       end}
    end,
    Bench.Config.benchee(title: "#{batch} calls, #{in_flight} in flight")
  )
after
  Bench.Config.stop_all(started)
end
