# Caller-process, Portals-process, and worker RSS measurement (Phase 8).
# Not a Benchee suite — a one-shot snapshot, since memory is a point-in-time
# property rather than a throughput/latency distribution.
#
#   mix run bench/memory_bench.exs
worker_script = Path.expand("../sdk/python/tests/fixtures/run_worker.py", __DIR__)

python! =
  System.find_executable("python3") ||
    raise "python3 not available; required to run bench/memory_bench.exs"

defmodule Portals.Bench.Memory do
  def beam_rss_kb do
    case File.read("/proc/self/status") do
      {:ok, contents} ->
        case Regex.run(~r/VmRSS:\s+(\d+) kB/, contents) do
          [_, kb] -> String.to_integer(kb)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  def os_pid_rss_kb(os_pid) when is_integer(os_pid) do
    case File.read("/proc/#{os_pid}/status") do
      {:ok, contents} ->
        case Regex.run(~r/VmRSS:\s+(\d+) kB/, contents) do
          [_, kb] -> String.to_integer(kb)
          nil -> nil
        end

      _ ->
        nil
    end
  end
end

caller_process_words_before = :erlang.process_info(self(), :memory)
beam_rss_before = Portals.Bench.Memory.beam_rss_kb()

{:ok, conn} = Portals.start_worker(command: python!, args: [worker_script])

for _ <- 1..1_000, do: {:ok, _} = Portals.call(conn, "bench_worker", "add", [1, 2])

portals_process_info = :erlang.process_info(conn, :memory)
caller_process_words_after = :erlang.process_info(self(), :memory)
beam_rss_after = Portals.Bench.Memory.beam_rss_kb()

worker_os_pid =
  case :sys.get_state(conn) do
    %{lifecycle_port: port} when is_port(port) ->
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    _ ->
      nil
  end

worker_rss_kb = worker_os_pid && Portals.Bench.Memory.os_pid_rss_kb(worker_os_pid)

IO.puts("caller process memory before: #{inspect(caller_process_words_before)}")
IO.puts("caller process memory after:  #{inspect(caller_process_words_after)}")
IO.puts("Portals.Connection process memory: #{inspect(portals_process_info)}")
IO.puts("BEAM RSS before: #{beam_rss_before} kB, after: #{beam_rss_after} kB")
IO.puts("worker OS pid: #{inspect(worker_os_pid)}, worker RSS: #{inspect(worker_rss_kb)} kB")

Portals.stop_worker(conn)
