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

  @star_points 4
  @dope_points 1

  # The vote types that count toward a score - the rest (boofstar, nope) don't.
  @scoring_vote_types ~w[dope star]

  schema "plays" do
    belongs_to :user, Rvrb.User
    field :spotify_track_id, :string
    field :track_name, :string
    field :artist_names, {:array, :string}, default: []
    field :spotify_artist_ids, {:array, :string}, default: []
    field :duration_ms, :integer
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
      :duration_ms,
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
  Covers both sides of the room: what `user_id` earned as a DJ, and what
  they handed out as a listener (the `favorite_*` entries).
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
      stars_received: Map.get(vote_counts, "star", 0),
      most_played: most_played(user_id),
      best_play: best_play(user_id),
      most_played_artist: most_played_artist(user_id),
      best_artist: best_artist(user_id),
      favorite_dj: favorite_dj(user_id),
      favorite_track: favorite_track(user_id),
      favorite_artist: favorite_artist(user_id)
    }
  end

  @doc """
  Average track length (in milliseconds) per user, for the given internal
  `user_ids`, as `%{user_id => %{avg_ms: integer, play_count: integer}}`.
  Backs the `\\rotation` estimate.

  Users with no timed plays are simply absent from the result rather than
  present with a nil average, so the caller can tell "never played" apart
  from "played, but we don't know how long for" and pick its own fallback.
  """
  def average_durations(user_ids) do
    from(p in Rvrb.Play,
      where: p.user_id in ^user_ids and not is_nil(p.duration_ms),
      group_by: p.user_id,
      select: {p.user_id, avg(p.duration_ms), count(p.id)}
    )
    |> Rvrb.Repo.all()
    |> Map.new(fn {user_id, avg_ms, play_count} ->
      {user_id, %{avg_ms: to_ms(avg_ms), play_count: play_count}}
    end)
  end

  @doc """
  Average track length (in milliseconds) across every timed play by
  anyone, or nil if nothing timed has been recorded yet. Used as the
  stand-in for a DJ we have no history for - the room's own taste in track
  length is a better guess than a hardcoded number.
  """
  def average_duration do
    from(p in Rvrb.Play, where: not is_nil(p.duration_ms), select: avg(p.duration_ms))
    |> Rvrb.Repo.one()
    |> to_ms()
  end

  # Postgres' avg() over an integer column comes back as a Decimal.
  defp to_ms(nil), do: nil
  defp to_ms(%Decimal{} = avg), do: avg |> Decimal.round() |> Decimal.to_integer()
  defp to_ms(avg) when is_float(avg), do: round(avg)
  defp to_ms(avg) when is_integer(avg), do: avg

  @doc "The track `user_id` has played the most times, or nil if they've never played anything."
  def most_played(user_id) do
    from(p in Rvrb.Play,
      where: p.user_id == ^user_id,
      group_by: [p.spotify_track_id, p.track_name, p.artist_names],
      select: %{
        track_name: p.track_name,
        artist_names: p.artist_names,
        play_count: count(p.id)
      },
      order_by: [desc: count(p.id)],
      limit: 1
    )
    |> Rvrb.Repo.one()
  end

  @doc """
  `user_id`'s single highest-scoring play - scored `star * 4 + dope * 1`,
  summed across everyone who voted on it - or nil if they've never played
  anything. A play nobody's voted on yet can still "win" with a score of
  0 if it's all the user has.
  """
  def best_play(user_id) do
    from(p in Rvrb.Play,
      left_join: v in Rvrb.PlayVote,
      on: v.play_id == p.id,
      where: p.user_id == ^user_id,
      group_by: p.id,
      select: %{
        track_name: p.track_name,
        artist_names: p.artist_names,
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.map(&with_score/1)
    |> Enum.max_by(& &1.score, fn -> nil end)
  end

  @doc """
  The artist `user_id` has played the most times, counting every play of
  every track that credits them (so a play with multiple artists counts
  toward each), or nil if they've never played anything.
  """
  def most_played_artist(user_id) do
    from(p in Rvrb.Play, where: p.user_id == ^user_id, select: p.artist_names)
    |> Rvrb.Repo.all()
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.max_by(fn {_artist, count} -> count end, fn -> nil end)
    |> case do
      nil -> nil
      {artist_name, play_count} -> %{artist_name: artist_name, play_count: play_count}
    end
  end

  @doc """
  The artist with the highest total score across `user_id`'s plays - each
  play scored the same way as in `best_play/1` and credited to every artist
  listed on it, then summed per artist - or nil if they've never played
  anything.
  """
  def best_artist(user_id) do
    from(p in Rvrb.Play,
      left_join: v in Rvrb.PlayVote,
      on: v.play_id == p.id,
      where: p.user_id == ^user_id,
      group_by: p.id,
      select: %{
        artist_names: p.artist_names,
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.flat_map(fn play ->
      Enum.map(play.artist_names, &{&1, score(play)})
    end)
    |> top_artist_by_score()
  end

  @doc """
  The DJ whose plays `user_id` has given the most points to, scored the
  same way as `best_play/1` but counting only the votes `user_id` cast
  themselves. Their own plays don't count - you can't be your own
  favorite DJ - and nil comes back if they've never doped or starred
  anyone.
  """
  def favorite_dj(user_id) do
    from(v in Rvrb.PlayVote,
      join: p in Rvrb.Play,
      on: v.play_id == p.id,
      join: u in Rvrb.User,
      on: p.user_id == u.id,
      where: ^votes_given_by(user_id),
      group_by: [u.id, u.display_name, u.user_name],
      select: %{
        display_name: u.display_name,
        user_name: u.user_name,
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.map(&with_score/1)
    |> Enum.max_by(& &1.score, fn -> nil end)
  end

  @doc """
  The track `user_id` has given the most points to across everyone else's
  plays of it, or nil if they've never doped or starred anything.
  """
  def favorite_track(user_id) do
    from(v in Rvrb.PlayVote,
      join: p in Rvrb.Play,
      on: v.play_id == p.id,
      where: ^votes_given_by(user_id),
      group_by: [p.spotify_track_id, p.track_name, p.artist_names],
      select: %{
        track_name: p.track_name,
        artist_names: p.artist_names,
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.map(&with_score/1)
    |> Enum.max_by(& &1.score, fn -> nil end)
  end

  @doc """
  The artist `user_id` has given the most points to, crediting every
  artist listed on a play they voted on, or nil if they've never doped or
  starred anything.
  """
  def favorite_artist(user_id) do
    from(v in Rvrb.PlayVote,
      join: p in Rvrb.Play,
      on: v.play_id == p.id,
      where: ^votes_given_by(user_id),
      select: %{artist_names: p.artist_names, vote_type: v.vote_type}
    )
    |> Rvrb.Repo.all()
    |> Enum.flat_map(fn vote ->
      Enum.map(vote.artist_names, &{&1, vote_points(vote.vote_type)})
    end)
    |> top_artist_by_score()
  end

  # Narrows the "favorite" queries - which all join a vote `v` to the play
  # `p` it was cast on - to the scoring votes `user_id` gave out on
  # somebody else's play, as opposed to the ones they got.
  defp votes_given_by(user_id) do
    dynamic(
      [v, p],
      v.voter_user_id == ^user_id and p.user_id != ^user_id and
        v.vote_type in ^@scoring_vote_types
    )
  end

  defp with_score(counts), do: Map.put(counts, :score, score(counts))

  defp score(%{stars: stars, dopes: dopes}), do: stars * @star_points + dopes * @dope_points

  defp vote_points("star"), do: @star_points
  defp vote_points("dope"), do: @dope_points
  defp vote_points(_), do: 0

  defp top_artist_by_score(artist_scores) do
    artist_scores
    |> Enum.reduce(%{}, fn {artist, score}, acc ->
      Map.update(acc, artist, score, &(&1 + score))
    end)
    |> Enum.max_by(fn {_artist, score} -> score end, fn -> nil end)
    |> case do
      nil -> nil
      {artist_name, score} -> %{artist_name: artist_name, score: score}
    end
  end
end
