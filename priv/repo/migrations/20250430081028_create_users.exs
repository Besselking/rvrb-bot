defmodule Rvrb.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :rvrb_id, :string, :unique
      add :user_name, :string
      add :display_name, :string
      add :country, :string
      add :created_date, :naive_datetime
    end

    create unique_index(:users, [:rvrb_id])
  end
end
