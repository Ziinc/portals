# Caller-process, Portals-process, and worker RSS measurement. Not a
# Benchee suite — memory is a point-in-time snapshot, not a
# throughput/latency distribution.
#
#     mix run memory.exs
defmodule Bench.Memory do
  def rss_kb(pid) when is_integer(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, contents} ->
        case Regex.run(~r/VmRSS:\s+(\d+) kB/, contents) do
          [_, kb] -> String.to_integer(kb)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  def beam_rss_kb, do: rss_kb(System.pid() |> String.to_integer())
end

target = Bench.Targets.portals(transport: :unix)
handle = target.start.()

caller_before = :erlang.process_info(self(), :memory)
beam_rss_before = Bench.Memory.beam_rss_kb()

for i <- 1..1_000, do: target.call.(handle, "add", [i, 1])

caller_after = :erlang.process_info(self(), :memory)
beam_rss_after = Bench.Memory.beam_rss_kb()
portals_info = :erlang.process_info(handle, :memory)

worker_rss_kb =
  case :sys.get_state(handle) do
    %{lifecycle_port: port} when is_port(port) ->
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> Bench.Memory.rss_kb(os_pid)
        _ -> nil
      end

    _ ->
      nil
  end

IO.puts("caller process memory before: #{inspect(caller_before)}")
IO.puts("caller process memory after:  #{inspect(caller_after)}")
IO.puts("Portals.Connection process memory: #{inspect(portals_info)}")
IO.puts("BEAM RSS before: #{beam_rss_before} kB, after: #{beam_rss_after} kB")
IO.puts("worker RSS: #{inspect(worker_rss_kb)} kB")

target.stop.(handle)
