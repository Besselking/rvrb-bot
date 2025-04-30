defmodule Rvrb.Repo.Migrations.AddLastDjed do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_djed, :naive_datetime
    end
  end
end
