defmodule PortalsJavaScript.MixProject do
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
      app: :portals_javascript,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "JavaScript worker SDK for Portals: call JavaScript from Elixir in supervised worker " <>
          "processes on Node.js, Bun, Deno or QuickJS.",
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
      links: %{
        "GitHub" => @source_url,
        "Guide" => "https://hexdocs.pm/portals_javascript/javascript.html"
      },
      files: [
        "lib",
        "priv/javascript/portals-worker/index.js",
        "priv/javascript/portals-worker/lib",
        "priv/javascript/portals-worker/package.json",
        "priv/javascript/register.cjs",
        "priv/javascript/quickjs/host.mjs",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "javascript",
      source_ref: "v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/v#{@version}/packages/portals_javascript/%{path}#L%{line}",
      extras: [
        "../../guides/languages/javascript.md": [
          filename: "javascript",
          title: "JavaScript guide"
        ]
      ]
    ]
  end
end
