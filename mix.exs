defmodule Portals.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Ziinc/portals"

  def project do
    [
      app: :portals,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_paths: ["test"],
      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "Call Python, Ruby, Node.js, PHP, Java and Go from Elixir through supervised, " <>
          "pooled worker processes. The spiritual successor to ErlPort.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  # Core ships no worker SDKs: each language is its own package
  # (packages/portals_<language>), released in lockstep with this one.
  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "protocol", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # The demo GIF embedded in README.md, at the same relative path.
      assets: %{"examples/hello_live/demo" => "examples/hello_live/demo"},
      extras: [
        "README.md": [title: "Overview"],
        "guides/getting-started.md": [title: "Getting started"],
        "guides/languages/python.md": [filename: "python", title: "Python"],
        "guides/languages/ruby.md": [filename: "ruby", title: "Ruby"],
        "guides/languages/javascript.md": [filename: "javascript", title: "JavaScript"],
        "guides/languages/php.md": [filename: "php", title: "PHP"],
        "guides/languages/java.md": [filename: "java", title: "Java"],
        "guides/languages/go.md": [filename: "go", title: "Go"],
        "protocol/v1.md": [filename: "protocol-v1", title: "Wire protocol v1"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Guides: ["README.md", "guides/getting-started.md"],
        Languages: Path.wildcard("guides/languages/*.md"),
        Reference: ["protocol/v1.md", "CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Calling workers": [Portals, Portals.Pool, Portals.Request, Portals.Stream],
        Errors: [Portals.Error, Portals.CallError],
        "Language packages": [Portals.SDK],
        "Callbacks & values": [Portals.Callback, Portals.Codec.Bin],
        "Conformance kit": [
          Portals.Conformance.Runner,
          Portals.Conformance.WorkerSuite,
          Portals.Conformance.SDKSuite,
          Portals.Fixtures.CallbackTarget
        ],
        Internals: [
          Portals.Connection,
          Portals.Protocol,
          Portals.Handshake,
          Portals.Codec,
          Portals.Codec.MessagePack,
          Portals.TermExtensions,
          Portals.Transport,
          Portals.Transport.Unix,
          Portals.Transport.Stdio,
          Portals.WorkerLifecycle.Port,
          Portals.SocketDir
        ]
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
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
