defmodule Rvrb.StatsTest do
  use Rvrb.DataCase, async: true

  alias Rvrb.Stats

  describe "totals/0" do
    test "counts nothing on an empty room" do
      assert %{plays: 0, votes: 0, dopes: 0, stars: 0, djs: 0, artists: 0} = Stats.totals()
      assert %{first_play_at: nil, last_play_at: nil} = Stats.totals()
    end

    test "counts plays, voters and the span they cover" do
      dj = user_fixture()
      listener = user_fixture()

      first =
        play_fixture(dj, %{
          spotify_track_id: "t1",
          artist_names: ["A", "B"],
          played_at: ~N[2026-01-01 12:00:00]
        })

      play_fixture(dj, %{
        spotify_track_id: "t2",
        artist_names: ["B"],
        played_at: ~N[2026-01-02 12:00:00]
      })

      vote_fixture(first, listener, "dope")
      vote_fixture(first, listener, "star")

      totals = Stats.totals()

      assert totals.plays == 2
      assert totals.tracks == 2
      # Two users exist, but only one of them has ever played anything.
      assert totals.users == 2
      assert totals.djs == 1
      # "A" and "B", counted once each however often they were played.
      assert totals.artists == 2
      assert totals.votes == 2
      assert totals.dopes == 1
      assert totals.stars == 1
      assert totals.first_play_at == "2026-01-01T12:00:00Z"
      assert totals.last_play_at == "2026-01-02T12:00:00Z"
    end
  end

  describe "plays_per_day/1" do
    test "returns one entry per day, oldest first, zeroes included" do
      dj = user_fixture()
      today = Date.utc_today()
      play_fixture(dj, %{played_at: NaiveDateTime.new!(today, ~T[10:00:00])})
      play_fixture(dj, %{played_at: NaiveDateTime.new!(today, ~T[11:00:00])})

      days = Stats.plays_per_day(3)

      assert length(days) == 3
      assert Enum.map(days, & &1.date) == Enum.map(-2..0, &Date.to_iso8601(Date.add(today, &1)))
      assert List.last(days) == %{date: Date.to_iso8601(today), plays: 2}
      assert Enum.take(days, 2) |> Enum.all?(&(&1.plays == 0))
    end

    test "leaves out plays older than the window" do
      dj = user_fixture()
      play_fixture(dj, %{played_at: ~N[2020-01-01 12:00:00]})

      assert Stats.plays_per_day(7) |> Enum.map(& &1.plays) |> Enum.sum() == 0
    end
  end

  describe "top_djs/1" do
    test "ranks by play count and scores what those plays earned" do
      quiet = user_fixture(%{display_name: "Quiet", user_name: "quiet"})
      busy = user_fixture(%{display_name: "Busy", user_name: "busy"})
      listener = user_fixture()

      quiet_play = play_fixture(quiet)
      for _ <- 1..3, do: play_fixture(busy)

      # One star on the quiet DJ's only play - enough for a score, not
      # enough to outrank three plays.
      vote_fixture(quiet_play, listener, "star")

      assert [
               %{name: "Busy", plays: 3, score: 0},
               %{name: "Quiet", plays: 1, stars: 1, score: 4}
             ] = Stats.top_djs(5)
    end

    test "falls back to the user name when there's no display name" do
      play_fixture(user_fixture(%{display_name: nil, user_name: "anon"}))

      assert [%{name: "anon"}] = Stats.top_djs(5)
    end

    test "honours the limit" do
      for _ <- 1..3, do: play_fixture(user_fixture())

      assert length(Stats.top_djs(2)) == 2
    end
  end

  describe "top_tracks/1" do
    test "groups plays of the same track by name and artists" do
      dj = user_fixture()
      other_dj = user_fixture()
      listener = user_fixture()

      # Same track, different Spotify ids - two albums, one track.
      play_fixture(dj, %{
        spotify_track_id: "album-version",
        track_name: "Windowlicker",
        artist_names: ["Aphex Twin"]
      })

      played_again =
        play_fixture(other_dj, %{
          spotify_track_id: "single-version",
          track_name: "Windowlicker",
          artist_names: ["Aphex Twin"]
        })

      play_fixture(dj, %{track_name: "Once", artist_names: ["Someone"]})
      vote_fixture(played_again, listener, "dope")

      assert [
               %{track_name: "Windowlicker", artist_names: ["Aphex Twin"], plays: 2, score: 1},
               %{track_name: "Once", plays: 1}
             ] = Stats.top_tracks(5)
    end
  end

  describe "top_artists/1" do
    test "credits every artist on a play, once per play" do
      dj = user_fixture()
      listener = user_fixture()

      collab = play_fixture(dj, %{artist_names: ["Solo", "Guest"]})
      play_fixture(dj, %{artist_names: ["Solo"]})

      # Two votes on one play: the split across its two artists must not
      # double them.
      vote_fixture(collab, listener, "dope")
      vote_fixture(collab, listener, "star")

      assert [
               %{artist_name: "Solo", plays: 2, dopes: 1, stars: 1, score: 5},
               %{artist_name: "Guest", plays: 1, dopes: 1, stars: 1, score: 5}
             ] = Stats.top_artists(5)
    end

    test "returns nothing when nothing has been played" do
      assert Stats.top_artists(5) == []
    end
  end

  describe "recent_plays/1" do
    test "returns the newest plays first, with their votes" do
      dj = user_fixture(%{display_name: "DJ", user_name: "dj"})
      listener = user_fixture()

      older = play_fixture(dj, %{track_name: "Older", played_at: ~N[2026-01-01 12:00:00]})
      play_fixture(dj, %{track_name: "Newer", played_at: ~N[2026-01-02 12:00:00]})
      vote_fixture(older, listener, "dope")

      assert [
               %{track_name: "Newer", dj: "DJ", played_at: "2026-01-02T12:00:00Z", score: 0},
               %{track_name: "Older", dopes: 1, score: 1}
             ] = Stats.recent_plays(5)
    end
  end

  describe "snapshot/1" do
    test "carries both halves, with the live one nil while the bot is down" do
      # The suite runs with `start_connection: false`, so there is no
      # socket process - the case a status page hits whenever the bot is
      # disconnected.
      play_fixture(user_fixture())

      snapshot = Stats.snapshot(limit: 1, days: 2)

      assert snapshot.live == nil
      assert snapshot.totals.plays == 1
      assert length(snapshot.plays_per_day) == 2
      assert length(snapshot.top_djs) == 1
      assert is_binary(snapshot.generated_at)
    end
  end
end
