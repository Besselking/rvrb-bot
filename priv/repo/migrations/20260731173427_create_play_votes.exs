defmodule Rvrb.Repo.Migrations.CreatePlayVotes do
  use Ecto.Migration

  def change do
    create table(:play_votes) do
      add :play_id, references(:plays), null: false
      add :voter_user_id, references(:users), null: false
      # Free text rather than a constrained enum: RVRB's own vote model
      # already has "boofstar" and "nope" alongside "dope"/"star", even
      # though only dope/star are wired up here right now.
      add :vote_type, :string, null: false
    end

    # One active vote of a given type per (play, voter): a vote is
    # inserted when a listener dopes/stars a track and deleted if they
    # take it back, rather than appended to as a log - `updateChannelMeter`
    # reports the room's current vote state on every update, not a delta.
    create unique_index(:play_votes, [:play_id, :voter_user_id, :vote_type])
    create index(:play_votes, [:voter_user_id])
  end
end
