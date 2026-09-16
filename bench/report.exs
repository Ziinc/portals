# Summarizes every Benchee JSON result under bench/results/ into one
# plain-text table (Phase 8's "report generator").
#
#   mix run bench/codec_micro_bench.exs   # writes bench/results/*.json
#   mix run bench/report.exs
results_dir = Path.expand("results", __DIR__)

json_files =
  results_dir
  |> File.ls!()
  |> Enum.filter(&String.ends_with?(&1, ".json"))
  |> Enum.sort()

if json_files == [] do
  IO.puts("No benchmark results found under #{results_dir}. Run a bench/*.exs script first.")
else
  Enum.each(json_files, fn file ->
    path = Path.join(results_dir, file)
    data = path |> File.read!() |> Jason.decode!()

    IO.puts("\n== #{file} ==")

    scenarios = if is_list(data), do: data, else: data["scenarios"] || []

    Enum.each(scenarios, fn scenario ->
      name = scenario["name"]
      input_name = scenario["input_name"]
      run_time = scenario["run_time_data"] || %{}
      stats = run_time["statistics"] || %{}
      average_ns = stats["average"] || 0.0
      ips = stats["ips"] || 0.0

      label = if input_name in [nil, "Input"], do: name, else: "#{name} (#{input_name})"

      :io.format("~-45s avg=~10.2f us  ips=~10.2f~n", [
        label,
        average_ns / 1000.0,
        ips
      ])
    end)
  end)
end
