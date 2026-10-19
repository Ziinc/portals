defmodule Bench.Config do
  @moduledoc """
  Shared Benchee settings. `BENCH_TIME` and `BENCH_WARMUP` (seconds,
  defaults 5 and 2) shorten or lengthen every run, e.g. `BENCH_TIME=1` for
  a quick look.
  """

  def benchee(opts \\ []) do
    Keyword.merge(
      [
        warmup: seconds("BENCH_WARMUP", 2),
        time: seconds("BENCH_TIME", 5),
        print: [fast_warning: false],
        formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
      ],
      opts
    )
  end

  defp seconds(var, default) do
    case System.get_env(var) do
      nil -> default
      value -> String.to_float(value <> if(String.contains?(value, "."), do: "", else: ".0"))
    end
  end

  @doc "Starts every `{name, target}`, returning `{name, target, handle}`."
  def start_all(targets) do
    Logger.configure(level: :warning)
    for {name, target} <- targets, do: {name, target, target.start.()}
  end

  def stop_all(started),
    do: Enum.each(started, fn {_, target, handle} -> target.stop.(handle) end)
end
