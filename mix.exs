defmodule Issho.MixProject do
  use Mix.Project

  @version "0.4.0"
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
      {:lazy_html, "~> 0.1", only: :test},
      {:phoenix, "~> 1.7.14 or ~> 1.8"},
      # Issho.Live, for apps with LiveView.
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:sake, "~> 0.4.4", optional: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:stream_data, "~> 1.1", only: :test},
      {:telemetry, "~> 1.0"}
    ]
  end

  defp description do
    "An open-source collaboration toolkit for Phoenix: rooms, presence, documents and agent participation, for apps where people and AI agents work together in real time."
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
        priv/static/types
        priv/static/issho.css
        priv/static/issho-sumi.css
        package.json
        .formatter.exs
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
      source_ref: "v#{@version}",
      source_url: @source_url,
      assets: %{"media" => "media"},
      extras: [
        "README.md",
        "guides/architecture.md",
        "guides/agents.md",
        "guides/components.md",
        "guides/state.md",
        "guides/comments.md",
        "guides/streams.md",
        "CHANGELOG.md"
      ],
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
        Comments: [Issho.Comments, Issho.Comments.Ops, Issho.Engine.Comments, Issho.Inbox],
        Streams: [Issho.Streams, Issho.Stream],
        Rooms: [
          Issho.Channel,
          Issho.Token,
          Issho.Presence,
          Issho.Awareness,
          Issho.Identity,
          Issho.Color
        ],
        LiveView: [Issho.Live, Issho.State],
        Agents: [Issho.Participant, Issho.Agents, Issho.Work, Issho.MCP.Inbox],
        Stores: [Issho.Store.Memory, Issho.Store.None],
        Testing: [Issho.Test]
      ]
    ]
  end

  defp aliases do
    [
      "assets.build": ["issho.build"],
      "test.js": ["cmd --cd assets npm test"],
      # The page layer in a browser: e2e/ (npm ci there, and Playwright's browsers).
      "test.e2e": ["cmd --cd e2e npm test"],
      # The build and the check run in a child VM, as in Hakushi: once
      # anything compiles in this VM, Mix no longer finds the tasks of the
      # Hex archive. The check refuses a priv/static with anything but the
      # bundle files.
      release: [
        "cmd mix issho.build",
        "cmd mix issho.release_check",
        "hex.publish --yes",
        "cmd git tag v#{@version} -f",
        "cmd git push",
        "cmd git push --tags"
      ],
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
