defmodule Rvrb.MixProject do
  use Mix.Project

  def project do
    [
      app: :rvrb,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :timex],
      mod: {Rvrb.Application, []},
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fresh, "~> 0.4.4"},
      {:poison, "~> 3.1"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.20.0"},
      {:timex, "~> 3.7.11"},
      {:spotify_ex, "~> 2.3"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
