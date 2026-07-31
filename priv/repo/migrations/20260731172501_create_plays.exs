defmodule Rvrb.Repo.Migrations.CreatePlays do
  use Ecto.Migration

  def change do
    create table(:plays) do
      add :user_id, references(:users), null: false
      add :spotify_track_id, :string
      add :track_name, :string, null: false
      add :artist_names, {:array, :string}, null: false, default: []
      add :spotify_artist_ids, {:array, :string}, null: false, default: []
      add :played_at, :naive_datetime, null: false
    end

    create index(:plays, [:user_id])
  end
end
