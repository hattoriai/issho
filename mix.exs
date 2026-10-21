defmodule Issho.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/hattoriai/issho"

  def project do
    [
      app: :issho,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :esbuild],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      package: package(),
      docs: docs(),
      description: description(),
      name: "Issho",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The end-to-end test serves a real endpoint to the browser client.
      {:bandit, "~> 1.5", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:esbuild, "~> 0.10", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:phoenix, "~> 1.7.14 or ~> 1.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:stream_data, "~> 1.1", only: :test},
      {:telemetry, "~> 1.0"}
    ]
  end

  defp description do
    "Collaboration for Phoenix: one engine for people and agents working together live, under every component on a page."
  end

  defp package do
    [
      name: "issho",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The bundle files by name: other build output in priv/static never
      # goes into the package.
      files: ~w(
        lib
        priv/static/issho.esm.js
        priv/static/issho.cjs.js
        package.json
        mix.exs
        .formatter.exs
        guides
        README.md
        CHANGELOG.md
        LICENSE
        NOTICE
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      assets: %{"media" => "media"},
      extras: ["README.md", "guides/architecture.md", "CHANGELOG.md"],
      groups_for_modules: [
        Contracts: [
          Issho.Actor,
          Issho.Policy,
          Issho.Engine,
          Issho.Place,
          Issho.Binding,
          Issho.Store
        ],
        Documents: [Issho.Authority, Issho.Documents, Issho.Transaction, Issho.Engine.Map],
        Rooms: [Issho.Channel, Issho.Token, Issho.Presence, Issho.Awareness, Issho.Identity],
        Agents: [Issho.Participant],
        Stores: [Issho.Store.Memory],
        Testing: [Issho.Test]
      ]
    ]
  end

  defp aliases do
    [
      "assets.build": ["issho.build"],
      "test.js": ["cmd --cd assets npm test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
