defmodule HelloLive.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_live,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {HelloLive.Application, []},
      extra_applications: [:logger]
    ]
  end

  # This example uses the packages in this repository. In your own
  # application, depend on the Hex releases instead, e.g.
  # {:portals_python, "~> 0.1.0"} (each one pulls in core `portals`).
  defp deps do
    [
      {:portals, path: "../..", override: true},
      {:portals_python, path: "../../packages/portals_python"},
      {:portals_ruby, path: "../../packages/portals_ruby"},
      {:portals_node, path: "../../packages/portals_node"},
      {:portals_php, path: "../../packages/portals_php"},
      {:portals_java, path: "../../packages/portals_java"},
      {:portals_go, path: "../../packages/portals_go"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  # The Java and Go workers are compiled programs: build them whenever the
  # Elixir code compiles (see lib/mix/tasks/hello_live.build_workers.ex).
  defp aliases do
    [
      compile: ["compile", "hello_live.build_workers"]
    ]
  end
end
