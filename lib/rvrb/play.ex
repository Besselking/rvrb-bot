defmodule Rvrb.Play do
  @moduledoc """
  One row per track a DJ plays to the room. Backs the `\\stats` command.

  `spotify_artist_ids` is captured even though nothing reads it yet, since
  it's the only way to answer artist/genre-based stats questions later
  ("what's your most-played genre?") - that data can't be reconstructed
  retroactively once a play has happened, so it's cheap to store now and
  expensive to have skipped.
  """
  use Ecto.Schema

  schema "plays" do
    belongs_to :user, Rvrb.User
    field :spotify_track_id, :string
    field :track_name, :string
    field :artist_names, {:array, :string}, default: []
    field :spotify_artist_ids, {:array, :string}, default: []
    field :doped, :boolean, default: false
    field :starred, :boolean, default: false
    field :played_at, :naive_datetime
  end

  def changeset(play, params \\ %{}) do
    play
    |> Ecto.Changeset.cast(params, [
      :user_id,
      :spotify_track_id,
      :track_name,
      :artist_names,
      :spotify_artist_ids,
      :doped,
      :starred,
      :played_at
    ])
    |> Ecto.Changeset.validate_required([:user_id, :track_name, :played_at])
    |> Ecto.Changeset.foreign_key_constraint(:user_id)
  end
end
