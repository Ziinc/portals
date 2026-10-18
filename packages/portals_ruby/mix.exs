defmodule PortalsRuby.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Ziinc/portals"

  # Inside the monorepo this package depends on core `portals` by path; a
  # published copy (or PORTALS_PUBLISH=1, set by scripts/release.sh)
  # depends on the identical Hex release instead. See RELEASING.md.
  @monorepo? File.exists?(Path.expand("../../.portals-monorepo", __DIR__)) and
               System.get_env("PORTALS_PUBLISH") != "1"

  def project do
    [
      app: :portals_ruby,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Ruby worker SDK for Portals: call Ruby from Elixir in supervised worker processes.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      portals_dep(),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp portals_dep do
    if @monorepo?, do: {:portals, path: "../.."}, else: {:portals, "~> #{@version}"}
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Guide" => "https://hexdocs.pm/portals_ruby/ruby.html"},
      files: [
        "lib",
        "priv/ruby/lib",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "ruby",
      source_ref: "v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/v#{@version}/packages/portals_ruby/%{path}#L%{line}",
      extras: [
        "../../guides/languages/ruby.md": [filename: "ruby", title: "Ruby guide"]
      ]
    ]
  end
end
