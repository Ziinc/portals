# Cold start: start a worker, make one call, stop it. Dominated by the
# Python interpreter, so the interpreter alone is the baseline.
#
#     mix run startup.exs
alias Bench.Targets

Logger.configure(level: :warning)
python = Bench.Python.executable()

cold_start = fn target ->
  fn ->
    handle = target.start.()
    3 = target.call.(handle, "add", [1, 2])
    target.stop.(handle)
  end
end

Benchee.run(
  %{
    "python -c pass (baseline)" => fn -> {_, 0} = System.cmd(python, ["-c", "pass"]) end,
    "Portals: Unix socket" => cold_start.(Targets.portals(transport: :unix)),
    "Portals: stdio" => cold_start.(Targets.portals(transport: :stdio)),
    "zerorpc" => cold_start.(Targets.zerorpc()),
    "ErlPort" => cold_start.(Targets.erlport())
  },
  Bench.Config.benchee(warmup: 1, title: "Start, one call, stop")
)
