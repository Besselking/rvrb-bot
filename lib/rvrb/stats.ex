defmodule Rvrb.Stats do
  @moduledoc """
  A read-only view of the bot: what the room is doing right now, and what
  it has done since the `plays` table started filling up.

  This is the module a reader outside the BEAM calls into. `bes.is` does
  it over Erlang distribution with [BeamSharp](https://github.com/Besselking/BeamSharp),
  a .NET node that dials this one and issues an ordinary `:erpc` call:

      :erpc.call(:"rvrb@host", Rvrb.Stats, :snapshot, [])

  so nothing here is HTTP-shaped and nothing new listens on a port. That
  puts one requirement on the deployment - the release has to run with
  distribution on, see `nix/module.nix` - and one on this module: every
  value it returns has to be a plain term the other side can read. Maps
  with atom keys, binaries, integers, nil. No structs (`NaiveDateTime`
  and `Date` are rendered as ISO 8601 binaries), no pids, no `MapSet`.

  Everything is a fresh query - there's no cache here, deliberately. A
  caller that polls is the one that knows how stale an answer it can
  live with, and the counts are cheap next to the round trip.
  """

  import Ecto.Query

  alias Rvrb.Play
  alias Rvrb.PlayVote
  alias Rvrb.Rotation
  alias Rvrb.User

  @star_points 4
  @dope_points 1

  # How many rows the leaderboards and the recent-plays list carry, and how
  # far back the per-day counts go. Enough to fill a page without turning a
  # status check into a table dump.
  @default_limit 5
  @default_days 14

  @doc """
  Everything a status page needs, in one round trip.

  Options:

    * `:limit` - rows per leaderboard, and recent plays (default #{@default_limit})
    * `:days` - how many days of per-day play counts (default #{@default_days})

  The `:live` half is nil when the bot isn't connected to RVRB; the
  historic half is always there, since it only needs the database.
  """
  def snapshot(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    days = Keyword.get(opts, :days, @default_days)

    %{
      generated_at: iso(NaiveDateTime.utc_now()),
      live: live(),
      totals: totals(),
      plays_per_day: plays_per_day(days),
      top_djs: top_djs(limit),
      top_tracks: top_tracks(limit),
      top_artists: top_artists(limit),
      recent_plays: recent_plays(limit)
    }
  end

  @doc """
  The room as the connection currently sees it, with DJ ids resolved to
  names and the `\\rotation` estimate folded in, or nil when the bot
  isn't connected.

  The estimate is computed here rather than on the socket process, since
  it needs the per-DJ track-length averages out of the database and the
  socket must never wait on Postgres - see `Rvrb.PlayWriter`.
  """
  def live do
    case Rvrb.WebSocket.live_state() do
      nil -> nil
      state -> live_view(state)
    end
  end

  defp live_view(state) do
    %{
      channel_id: state.channel_id,
      current_track: current_track(state),
      dopes: length(state.dopes),
      stars: length(state.stars),
      auto_doped: state.auto_doped,
      auto_starred: state.auto_starred,
      queued_tracks: state.queued_tracks,
      known_bots: state.known_bots
    }
    |> Map.merge(rotation(state))
  end

  defp current_track(%{current_track: nil}), do: nil

  defp current_track(%{current_track: track} = state) do
    Map.merge(track, %{elapsed_ms: state.elapsed_ms, remaining_ms: state.remaining_ms})
  end

  # The DJ queue with a name and a wait per slot. `%{djs: [], lap_ms: 0}`
  # when nobody is DJing, which is a real state of the room rather than a
  # failure - the queue empties out every night.
  defp rotation(%{djs: []}), do: %{djs: [], lap_ms: 0}

  defp rotation(%{djs: djs} = state) do
    estimate =
      Rotation.estimate(djs, dj_averages(djs),
        remaining_ms: state.remaining_ms,
        fallback_ms: Play.average_duration()
      )

    dj_map = User.get_users(djs)

    entries =
      for entry <- estimate.entries do
        %{
          rvrb_id: entry.dj,
          name: User.get_name(dj_map, entry.dj),
          avg_track_ms: entry.duration_ms,
          play_count: entry.play_count,
          measured: entry.measured?,
          current: entry.current?,
          wait_ms: entry.wait_ms
        }
      end

    %{djs: entries, lap_ms: estimate.total_ms}
  end

  # Average track length per DJ, keyed by the RVRB ids the queue uses
  # rather than the internal user ids the plays table is keyed by. Same
  # shape `Rvrb.Commands` builds for `\rotation`.
  defp dj_averages(djs) do
    user_ids = User.get_ids(djs)
    averages = Play.average_durations(Map.values(user_ids))

    Map.new(user_ids, fn {rvrb_id, user_id} -> {rvrb_id, averages[user_id]} end)
  end

  @doc "Room-wide counts: how much has been played, voted on, and by how many people."
  def totals do
    vote_counts =
      from(v in PlayVote, group_by: v.vote_type, select: {v.vote_type, count(v.id)})
      |> Rvrb.Repo.all()
      |> Map.new()

    play_span =
      from(p in Play, select: {count(p.id), min(p.played_at), max(p.played_at)})
      |> Rvrb.Repo.one()

    {plays, first_play_at, last_play_at} = play_span

    %{
      plays: plays,
      votes: vote_counts |> Map.values() |> Enum.sum(),
      dopes: Map.get(vote_counts, "dope", 0),
      stars: Map.get(vote_counts, "star", 0),
      users: Rvrb.Repo.one(from(u in User, select: count(u.id))),
      djs: Rvrb.Repo.one(from(p in Play, select: count(p.user_id, :distinct))),
      # Nulls drop out of a distinct count, so a play RVRB gave us no
      # Spotify id for simply doesn't count toward the track total.
      tracks: Rvrb.Repo.one(from(p in Play, select: count(p.spotify_track_id, :distinct))),
      artists:
        Rvrb.Repo.one(from(a in subquery(distinct_artists()), select: count(a.artist_name))),
      first_play_at: iso(first_play_at),
      last_play_at: iso(last_play_at)
    }
  end

  @doc """
  Plays per day for the last `days` days, oldest first, as
  `[%{date: "2026-09-07", plays: 12}]`.

  Days nothing was played on come back as zeroes rather than as gaps: a
  chart drawn from this should show the quiet Tuesday, not close it up.
  """
  def plays_per_day(days \\ @default_days) do
    today = Date.utc_today()
    since = Date.add(today, -(days - 1))

    counted =
      from(p in Play,
        where: p.played_at >= ^NaiveDateTime.new!(since, ~T[00:00:00]),
        group_by: fragment("date(?)", p.played_at),
        select: {fragment("date(?)", p.played_at), count(p.id)}
      )
      |> Rvrb.Repo.all()
      |> Map.new()

    for offset <- 0..(days - 1) do
      date = Date.add(since, offset)
      %{date: Date.to_iso8601(date), plays: Map.get(counted, date, 0)}
    end
  end

  @doc "The DJs with the most plays, with what those plays earned them."
  def top_djs(limit \\ @default_limit) do
    from(p in Play,
      join: u in User,
      on: u.id == p.user_id,
      left_join: v in PlayVote,
      on: v.play_id == p.id,
      group_by: u.id,
      order_by: [desc: count(p.id, :distinct), desc: u.id],
      limit: ^limit,
      select: %{
        name: fragment("coalesce(nullif(?, ''), ?)", u.display_name, u.user_name),
        user_name: u.user_name,
        # Distinct, because the left join fans each play out into one row
        # per vote cast on it.
        plays: count(p.id, :distinct),
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.map(&with_score/1)
  end

  @doc """
  The most-played tracks. Grouped by name and artists rather than by
  Spotify id, so the same track queued from two different albums still
  counts once, and a play that arrived without an id still counts at all.
  """
  def top_tracks(limit \\ @default_limit) do
    from(p in Play,
      left_join: v in PlayVote,
      on: v.play_id == p.id,
      group_by: [p.track_name, p.artist_names],
      order_by: [desc: count(p.id, :distinct), asc: p.track_name],
      limit: ^limit,
      select: %{
        track_name: p.track_name,
        artist_names: p.artist_names,
        plays: count(p.id, :distinct),
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.map(&with_score/1)
  end

  @doc """
  The most-played artists. A play credits every artist listed on it, so a
  collaboration counts once for each of them.
  """
  def top_artists(limit \\ @default_limit) do
    # Scored per play first, then exploded: unnesting before the votes are
    # counted would multiply every vote by the number of artists on the
    # track.
    scored =
      from(p in Play,
        left_join: v in PlayVote,
        on: v.play_id == p.id,
        group_by: p.id,
        select: %{
          id: p.id,
          artist_names: p.artist_names,
          dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
          stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
        }
      )

    per_artist =
      from(s in subquery(scored),
        select: %{
          play_id: s.id,
          artist_name: fragment("unnest(?)", s.artist_names),
          dopes: s.dopes,
          stars: s.stars
        }
      )

    from(a in subquery(per_artist),
      group_by: a.artist_name,
      order_by: [desc: count(a.play_id), asc: a.artist_name],
      limit: ^limit,
      select: %{
        artist_name: a.artist_name,
        plays: count(a.play_id),
        dopes: sum(a.dopes),
        stars: sum(a.stars)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.map(&with_score/1)
  end

  @doc "The last `limit` tracks played, newest first."
  def recent_plays(limit \\ @default_limit) do
    from(p in Play,
      join: u in User,
      on: u.id == p.user_id,
      left_join: v in PlayVote,
      on: v.play_id == p.id,
      group_by: [p.id, u.id],
      order_by: [desc: p.played_at, desc: p.id],
      limit: ^limit,
      select: %{
        played_at: p.played_at,
        dj: fragment("coalesce(nullif(?, ''), ?)", u.display_name, u.user_name),
        track_name: p.track_name,
        artist_names: p.artist_names,
        duration_ms: p.duration_ms,
        dopes: fragment("count(*) filter (where ? = 'dope')", v.vote_type),
        stars: fragment("count(*) filter (where ? = 'star')", v.vote_type)
      }
    )
    |> Rvrb.Repo.all()
    |> Enum.map(fn play -> play |> with_score() |> Map.update!(:played_at, &iso/1) end)
  end

  # Every distinct artist name across every play, one row each.
  defp distinct_artists do
    from(p in Play, select: %{artist_name: fragment("distinct unnest(?)", p.artist_names)})
  end

  # Scored the same way `Rvrb.Play` scores a play, so a number here and a
  # number in `\stats` mean the same thing. `sum/1` hands back a Decimal
  # (or nil, for an artist nobody voted on), which has to become an
  # integer before it goes over the wire.
  defp with_score(counts) do
    dopes = to_integer(counts.dopes)
    stars = to_integer(counts.stars)

    %{counts | dopes: dopes, stars: stars}
    |> Map.put(:score, stars * @star_points + dopes * @dope_points)
  end

  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value

  # Timestamps travel as ISO 8601 binaries: a NaiveDateTime is a struct,
  # and a struct is a map with a `__struct__` key the reader would have to
  # know about. Everything stored is UTC, so the `Z` is earned.
  defp iso(nil), do: nil
  defp iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"
end
