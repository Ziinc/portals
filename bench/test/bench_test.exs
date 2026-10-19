defmodule BenchTest do
  @moduledoc """
  Smoke tests: every target and transport the benchmarks measure returns
  exactly what it was sent, so a benchmark never times a failing call.
  """

  use ExUnit.Case, async: false

  alias Bench.{Payloads, Targets, Transports}

  for {name, target} <- [
        {"Portals pool", quote(do: Targets.portals(size: 2))},
        {"ErlPort, 2 instances", quote(do: Targets.erlport(instances: 2))}
        | Enum.map(Targets.rpc(), fn {name, _} -> {name, nil} end)
      ] do
    test "#{name} echoes every workload" do
      target = unquote(target) || Map.new(Targets.rpc())[unquote(name)]
      handle = target.start.()

      try do
        assert target.call.(handle, "add", [1, 2]) == 3

        for {_name, spec} <- Payloads.echo_specs() do
          payload = Payloads.build(spec, target.wrap_bytes)
          assert normalize(target.call.(handle, "echo", [payload])) == normalize(payload)
        end
      after
        target.stop.(handle)
      end
    end
  end

  for {name, _} <- Transports.all() do
    test "#{name} echoes every frame size" do
      transport = Map.new(Transports.all())[unquote(name)]
      handle = transport.start.()
      # Lent to the test process, as to each Benchee scenario.
      :ok = transport.claim.(handle)

      try do
        for {_name, size} <- Payloads.frame_sizes() do
          frame = :binary.copy(<<7>>, size)
          assert transport.round_trip.(handle, frame) == frame
        end
      after
        transport.stop.(handle)
      end
    end
  end

  # Each library's binary wrapper versus the plain binary it carries.
  defp normalize(%Portals.Codec.Bin{data: data}), do: data
  defp normalize(%Msgpax.Bin{data: data}), do: data
  defp normalize(other), do: other
end
