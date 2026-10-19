defmodule PortalsBench.MixProject do
  use Mix.Project

  # The benchmark suite: Portals against ETF, zerorpc and ErlPort, plus the
  # codecs and transports underneath. See README.md.
  def project do
    [
      app: :portals_bench,
      version: "0.0.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:portals, path: "..", override: true},
      {:portals_python, path: "../packages/portals_python"},
      {:benchee, "~> 1.3"},
      # Comparators: MessagePack and JSON codecs, ZeroMQ (for zerorpc) and
      # ErlPort.
      {:msgpax, "~> 2.4"},
      {:jason, "~> 1.4"},
      {:chumak, "~> 1.5"},
      {:erlport, "~> 0.11"}
    ]
  end
end
