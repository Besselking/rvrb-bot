defmodule Rvrb.Release do
  @moduledoc """
  Migration helpers for use in a compiled release, which has no `mix`
  available. Run with e.g. `bin/rvrb eval "Rvrb.Release.migrate"`.
  """

  @app :rvrb

  def migrate do
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.load(@app)
    Application.fetch_env!(@app, :ecto_repos)
  end
end
