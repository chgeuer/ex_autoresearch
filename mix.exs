defmodule ExAutoresearch.MixProject do
  use Mix.Project

  # Pre-built XLA archives from xla_rocm — skips the hour-long Bazel build.
  # Set XLA_BUILD=true to build from source instead.
  # For Blackwell (RTX 5070) / CUDA 13, you need the xla_rocm custom build.
  xla_rocm_archive_url =
    "https://github.com/chgeuer/xla_rocm/releases/download/v0.9.2-rocm/xla_extension-0.9.1-x86_64-linux-gnu-rocm.tar.gz"

  unless System.get_env("XLA_BUILD") do
    case System.get_env("XLA_TARGET") do
      "rocm" ->
        System.put_env(
          "XLA_ARCHIVE_URL",
          System.get_env("XLA_ARCHIVE_URL") || xla_rocm_archive_url
        )

        System.put_env("XLA_TARGET", "rocm")

      "cuda" ->
        # For Blackwell GPUs, set XLA_ARCHIVE_URL to a custom CUDA build from xla_rocm,
        # or set XLA_BUILD=true to build from source with CUDA support.
        System.put_env("XLA_TARGET", "cuda")

      _ ->
        # Default to ROCm (Framework Laptop iGPU)
        System.put_env(
          "XLA_ARCHIVE_URL",
          System.get_env("XLA_ARCHIVE_URL") || xla_rocm_archive_url
        )

        System.put_env("XLA_TARGET", "rocm")
    end
  end

  System.put_env("CC", System.get_env("CC") || "clang")
  System.put_env("CXX", System.get_env("CXX") || "clang++")

  def project do
    [
      app: :ex_autoresearch,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ExAutoresearch.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:tidewave, "~> 0.5", only: [:dev]},
      {:live_debugger, "~> 0.6", only: [:dev]},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.7"},
      # {:ash_admin, "~> 0.14"},  # conflicts with jido's gettext requirement
      {:ash_sqlite, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:nimble_options, "~> 1.1"},

      # ML / GPU
      {:nx, "~> 0.10.0"},
      {:exla, "~> 0.10.0"},
      {:axon, "~> 0.7"},
      {:polaris, "~> 0.1"},

      # Data
      # {:arrow, "~> 0.1", only: [:dev, :test]},

      # Agent / LLM backends
      {:jido_ghcopilot, path: Path.expand("~/github/agentjido/jido_ghcopilot")},
      {:claude_agent_sdk, "~> 0.14"},
      {:gemini_cli_sdk, "~> 0.1"},
      # Required transitive overrides (not on hex.pm)
      {:jido_shell, path: Path.expand("~/github/agentjido/jido_shell"), override: true},
      {:jido_harness, path: Path.expand("~/github/agentjido/jido_harness"), override: true},
      {:jido_vfs, path: Path.expand("~/github/agentjido/jido_vfs"), override: true},
      {:sprites, github: "mikehostetler/sprites-ex", override: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind ex_autoresearch", "esbuild ex_autoresearch"],
      "assets.deploy": [
        "tailwind ex_autoresearch --minify",
        "esbuild ex_autoresearch --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "ash.setup": ["ash.setup", "run priv/repo/seeds.exs"]
    ]
  end
end
