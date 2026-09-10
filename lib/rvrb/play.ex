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

  # How many of a DJ's most recent plays `average_durations/1` averages
  # over. Long enough to smooth out the odd interlude or 10 minute epic,
  # short enough that a DJ who's switched vibe this session is judged on
  # what they're playing now rather than on everything they've ever played.
  @recent_play_limit 25

  schema "plays" do
    belongs_to(:user, Rvrb.User)
    field(:spotify_track_id, :string)
    field(:track_name, :string)
    field(:artist_names, {:array, :string}, default: [])
    field(:spotify_artist_ids, {:array, :string}, default: [])
    field(:duration_ms, :integer)
    field(:played_at, :naive_datetime)
    has_many(:votes, Rvrb.PlayVote)
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

  Only each user's most recent #{@recent_play_limit} timed plays count
  toward their average: DJs drift between genres, and a lifetime average
  drags a DJ who's currently deep in 8 minute techno back toward the 3
  minute pop they played months ago. `play_count` is how many plays the
  average actually covers, so it tops out at #{@recent_play_limit}.

  Users with no timed plays are simply absent from the result rather than
  present with a nil average, so the caller can tell "never played" apart
  from "played, but we don't know how long for" and pick its own fallback.
  """
  def average_durations(user_ids) do
    # Rank each user's timed plays newest first, then average the ones
    # inside the window. Doing it in one query - rather than a query per
    # DJ - keeps the whole queue to a single round trip.
    recent_plays =
      from(p in Rvrb.Play,
        where: p.user_id in ^user_ids and not is_nil(p.duration_ms),
        windows: [by_user: [partition_by: p.user_id, order_by: [desc: p.played_at, desc: p.id]]],
        select: %{
          user_id: p.user_id,
          duration_ms: p.duration_ms,
          recency: over(row_number(), :by_user)
        }
      )

    from(p in subquery(recent_plays),
      where: p.recency <= ^@recent_play_limit,
      group_by: p.user_id,
      select: {p.user_id, avg(p.duration_ms), count(p.user_id)}
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
      # Ranked in Postgres rather than by loading every play the user has
      # ever spun and sorting in Elixir - the socket process waits on this.
      # Oldest play breaks a tie, so a repeat `\stats` gives the same answer.
      order_by: [
        desc:
          fragment(
            "count(*) filter (where ? = 'star') * ? + count(*) filter (where ? = 'dope') * ?",
            v.vote_type,
            ^@star_points,
            v.vote_type,
            ^@dope_points
          ),
        asc: p.id
      ],
      limit: 1,
      select: %{
        track_name: p.track_name,
        artist_names: p.artist_names,
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.one()
    |> case do
      nil -> nil
      play -> with_score(play)
    end
  end

  @doc """
  The artist `user_id` has played the most times, counting every play of
  every track that credits them (so a play with multiple artists counts
  toward each), or nil if they've never played anything.
  """
  def most_played_artist(user_id) do
    # Counted in Postgres rather than by loading every play and tallying in
    # Elixir. Name breaks a tie, so a repeat `\stats` gives the same answer.
    per_artist =
      from(p in Rvrb.Play,
        where: p.user_id == ^user_id,
        select: %{artist_name: fragment("unnest(?)", p.artist_names)}
      )

    from(a in subquery(per_artist),
      group_by: a.artist_name,
      order_by: [desc: count(a.artist_name), asc: a.artist_name],
      limit: 1,
      select: %{artist_name: a.artist_name, play_count: count(a.artist_name)}
    )
    |> Rvrb.Repo.one()
  end

  @doc """
  The artist with the highest total score across `user_id`'s plays - each
  play scored the same way as in `best_play/1` and credited to every artist
  listed on it, then summed per artist - or nil if they've never played
  anything.
  """
  def best_artist(user_id) do
    # Scored per play first, then exploded: unnesting before the votes are
    # counted would multiply every vote by the number of artists on the
    # track. Same shape as `Rvrb.Stats.top_artists/1`, and same reason.
    scored =
      from(p in Rvrb.Play,
        left_join: v in Rvrb.PlayVote,
        on: v.play_id == p.id,
        where: p.user_id == ^user_id,
        group_by: p.id,
        select: %{
          artist_names: p.artist_names,
          score:
            fragment(
              "count(*) filter (where ? = 'star') * ? + count(*) filter (where ? = 'dope') * ?",
              v.vote_type,
              ^@star_points,
              v.vote_type,
              ^@dope_points
            )
        }
      )

    from(s in subquery(scored),
      select: %{artist_name: fragment("unnest(?)", s.artist_names), score: s.score}
    )
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
    # `votes_given_by/1` has already narrowed this to the scoring types, so
    # the `else` arm is the dope case rather than a catch-all. The points
    # are the only thing in the branch, so they need `type/2` to tell
    # Postgres what they are - it infers text for a bare parameter, and the
    # sum outside then has nothing to add up.
    scored =
      from(v in Rvrb.PlayVote,
        join: p in Rvrb.Play,
        on: v.play_id == p.id,
        where: ^votes_given_by(user_id),
        select: %{
          artist_names: p.artist_names,
          score:
            fragment(
              "case when ? = 'star' then ? else ? end",
              v.vote_type,
              type(^@star_points, :integer),
              type(^@dope_points, :integer)
            )
        }
      )

    from(s in subquery(scored),
      select: %{artist_name: fragment("unnest(?)", s.artist_names), score: s.score}
    )
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

  @doc """
  What a play with `stars` and `dopes` on it is worth: a star counts for
  #{@star_points} points, a dope for #{@dope_points}.

  Public because this module owns the scale. `Rvrb.Stats` scores the same
  rows for the status page and calls through to here, so a number there
  and a number in `\\stats` can't drift apart.
  """
  def score(%{stars: stars, dopes: dopes}), do: stars * @star_points + dopes * @dope_points

  # Takes a query of `%{artist_name, score}` rows - one per artist per play
  # - and returns the artist with the highest total, or nil for no rows at
  # all. Summed and ranked in Postgres: the socket process waits on this,
  # and the row count grows with every play and every vote. Name breaks a
  # tie, so a repeat `\stats` gives the same answer.
  defp top_artist_by_score(per_artist) do
    from(a in subquery(per_artist),
      group_by: a.artist_name,
      order_by: [desc: sum(a.score), asc: a.artist_name],
      limit: 1,
      select: %{artist_name: a.artist_name, score: sum(a.score)}
    )
    |> Rvrb.Repo.one()
    |> case do
      nil -> nil
      artist -> %{artist | score: to_integer(artist.score)}
    end
  end

  # Postgres' sum() over an integer column comes back as a Decimal.
  defp to_integer(%Decimal{} = score), do: Decimal.to_integer(score)
  defp to_integer(score) when is_integer(score), do: score
end
