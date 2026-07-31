defmodule Rvrb.Play do
  @moduledoc """
  One row per track a DJ plays to the room. Backs the `\\stats` command.

  `spotify_artist_ids` is captured even though nothing reads it yet, since
  it's the only way to answer artist/genre-based stats questions later
  ("what's your most-played genre?") - that data can't be reconstructed
  retroactively once a play has happened, so it's cheap to store now and
  expensive to have skipped.

  Who doped/starred a play lives in `Rvrb.PlayVote`, not on this schema -
  see its moduledoc for why.
  """
  use Ecto.Schema

  import Ecto.Query

  schema "plays" do
    belongs_to :user, Rvrb.User
    field :spotify_track_id, :string
    field :track_name, :string
    field :artist_names, {:array, :string}, default: []
    field :spotify_artist_ids, {:array, :string}, default: []
    field :played_at, :naive_datetime
    has_many :votes, Rvrb.PlayVote
  end

  def changeset(play, params \\ %{}) do
    play
    |> Ecto.Changeset.cast(params, [
      :user_id,
      :spotify_track_id,
      :track_name,
      :artist_names,
      :spotify_artist_ids,
      :played_at
    ])
    |> Ecto.Changeset.validate_required([:user_id, :track_name, :played_at])
    |> Ecto.Changeset.foreign_key_constraint(:user_id)
  end

  def record(attrs) do
    %Rvrb.Play{}
    |> changeset(attrs)
    |> Rvrb.Repo.insert()
  end

  @doc """
  Play-count and dope/star totals for `user_id`, for the `\\stats` command.
  """
  def stats_for(user_id) do
    play_count =
      from(p in Rvrb.Play, where: p.user_id == ^user_id, select: count(p.id))
      |> Rvrb.Repo.one()

    vote_counts =
      from(v in Rvrb.PlayVote,
        join: p in Rvrb.Play,
        on: v.play_id == p.id,
        where: p.user_id == ^user_id,
        group_by: v.vote_type,
        select: {v.vote_type, count(v.id)}
      )
      |> Rvrb.Repo.all()
      |> Enum.into(%{})

    %{
      play_count: play_count,
      dopes_received: Map.get(vote_counts, "dope", 0),
      stars_received: Map.get(vote_counts, "star", 0)
    }
  end
end
