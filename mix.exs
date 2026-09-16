defmodule Portals.MixProject do
  use Mix.Project

  def project do
    [
      app: :portals,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_paths: ["test"],
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package()
    ]
  end

  # All three 1.0 worker SDKs ship inside the package itself (Phase 7 exit
  # criteria), so `mix deps.get` is all an application needs to run a
  # Python, Ruby, or Node worker.
  defp package do
    [
      licenses: ["MIT"],
      files: [
        "lib",
        "protocol",
        "sdk/python/portals",
        "sdk/ruby/lib",
        "sdk/node/index.js",
        "sdk/node/lib",
        "sdk/node/package.json",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
