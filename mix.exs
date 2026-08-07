defmodule Rvrb.MixProject do
  use Mix.Project

  def project do
    [
      app: :rvrb,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # test/support holds the DataCase and fixture helpers - compiled modules
  # rather than test files, so they're only on the path in test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `mix test` needs the test database to exist and be migrated - do it here
  # so a local run and a CI run go through exactly the same steps.
  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :timex],
      mod: {Rvrb.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Vendored, not pulled from Hex - see vendor/fresh/README.md for why.
      {:fresh, path: "vendor/fresh"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.20.0"},
      {:timex, "~> 3.7.11"},
      {:spotify_ex, "~> 2.3"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
