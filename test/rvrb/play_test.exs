defmodule Rvrb.PlayTest do
  use Rvrb.DataCase, async: true

  alias Rvrb.Play

  describe "record/1" do
    test "stores a play" do
      user = user_fixture()

      assert {:ok, play} =
               Play.record(%{
                 user_id: user.id,
                 track_name: "Windowlicker",
                 artist_names: ["Aphex Twin"],
                 played_at: ~N[2026-01-01 12:00:00]
               })

      assert Repo.get!(Play, play.id).track_name == "Windowlicker"
    end

    test "refuses a play with no track or DJ" do
      assert {:error, changeset} = Play.record(%{})
      assert %{user_id: [_], track_name: [_], played_at: [_]} = errors_on(changeset)
    end
  end

  describe "most_played/1" do
    test "returns nil for a user with no plays" do
      assert Play.most_played(user_fixture().id) == nil
    end

    test "returns the track with the most plays by that user" do
      user = user_fixture()
      play_fixture(user, %{spotify_track_id: "t1", track_name: "Once", artist_names: ["A"]})

      for _ <- 1..3 do
        play_fixture(user, %{spotify_track_id: "t2", track_name: "Thrice", artist_names: ["B"]})
      end

      assert %{track_name: "Thrice", artist_names: ["B"], play_count: 3} =
               Play.most_played(user.id)
    end

    test "ignores plays by other users" do
      user = user_fixture()
      other = user_fixture()
      play_fixture(user, %{spotify_track_id: "t1", track_name: "Mine"})

      for _ <- 1..5,
          do: play_fixture(other, %{spotify_track_id: "t2", track_name: "Theirs"})

      assert %{track_name: "Mine", play_count: 1} = Play.most_played(user.id)
    end
  end

  describe "best_play/1" do
    test "returns nil for a user with no plays" do
      assert Play.best_play(user_fixture().id) == nil
    end

    test "scores a star as four dopes" do
      user = user_fixture()
      four_dopes = play_fixture(user, %{track_name: "Four dopes"})
      one_star = play_fixture(user, %{track_name: "One star"})

      for _ <- 1..4, do: vote_fixture(four_dopes, user_fixture(), "dope")
      vote_fixture(one_star, user_fixture(), "star")

      # A 4-1 tie either way, so both of these are legitimate winners; what
      # matters is that the two arrive at the same score.
      assert %{score: 4} = Play.best_play(user.id)
    end

    test "sums dopes and stars cast by different listeners on one play" do
      user = user_fixture()
      play = play_fixture(user, %{track_name: "Loved", artist_names: ["A", "B"]})
      vote_fixture(play, user_fixture(), "star")
      vote_fixture(play, user_fixture(), "dope")
      vote_fixture(play, user_fixture(), "dope")

      assert %{track_name: "Loved", artist_names: ["A", "B"], stars: 1, dopes: 2, score: 6} =
               Play.best_play(user.id)
    end

    test "ignores non-scoring vote types" do
      user = user_fixture()
      play = play_fixture(user)
      vote_fixture(play, user_fixture(), "nope")
      vote_fixture(play, user_fixture(), "boofstar")

      assert %{dopes: 0, stars: 0, score: 0} = Play.best_play(user.id)
    end

    test "a play nobody voted on still wins when it's all the user has" do
      user = user_fixture()
      play_fixture(user, %{track_name: "Unloved"})

      assert %{track_name: "Unloved", score: 0} = Play.best_play(user.id)
    end

    test "ignores votes cast on somebody else's play" do
      user = user_fixture()
      other = user_fixture()
      play_fixture(user, %{track_name: "Mine"})
      theirs = play_fixture(other, %{track_name: "Theirs"})
      for _ <- 1..3, do: vote_fixture(theirs, user_fixture(), "star")

      assert %{track_name: "Mine", score: 0} = Play.best_play(user.id)
    end
  end

  describe "most_played_artist/1" do
    test "returns nil for a user with no plays" do
      assert Play.most_played_artist(user_fixture().id) == nil
    end

    test "counts a multi-artist play toward every artist on it" do
      user = user_fixture()
      play_fixture(user, %{artist_names: ["Solo"]})
      play_fixture(user, %{artist_names: ["Duo A", "Duo B"]})
      play_fixture(user, %{artist_names: ["Duo B", "Duo C"]})

      assert %{artist_name: "Duo B", play_count: 2} = Play.most_played_artist(user.id)
    end

    test "ignores plays by other users" do
      user = user_fixture()
      other = user_fixture()
      play_fixture(user, %{artist_names: ["Mine"]})
      for _ <- 1..4, do: play_fixture(other, %{artist_names: ["Theirs"]})

      assert %{artist_name: "Mine", play_count: 1} = Play.most_played_artist(user.id)
    end
  end

  describe "best_artist/1" do
    test "returns nil for a user with no plays" do
      assert Play.best_artist(user_fixture().id) == nil
    end

    test "sums an artist's score across every play crediting them" do
      user = user_fixture()
      first = play_fixture(user, %{artist_names: ["Spread", "Other"]})
      second = play_fixture(user, %{artist_names: ["Spread"]})
      big = play_fixture(user, %{artist_names: ["Single Hit"]})

      # Spread: 1 dope + 1 dope = 2. Single Hit: one star = 4.
      vote_fixture(first, user_fixture(), "dope")
      vote_fixture(second, user_fixture(), "dope")
      vote_fixture(big, user_fixture(), "star")

      assert %{artist_name: "Single Hit", score: 4} = Play.best_artist(user.id)
    end

    test "an unvoted artist still wins when nobody has scored at all" do
      user = user_fixture()
      play_fixture(user, %{artist_names: ["Only One"]})

      assert %{artist_name: "Only One", score: 0} = Play.best_artist(user.id)
    end
  end

  describe "favorite_dj/1" do
    test "returns nil when the user has never voted" do
      assert Play.favorite_dj(user_fixture().id) == nil
    end

    test "picks the DJ they've given the most points to" do
      voter = user_fixture()
      liked = user_fixture(%{user_name: "liked", display_name: "Liked DJ"})
      tolerated = user_fixture(%{user_name: "tolerated"})

      vote_fixture(play_fixture(liked), voter, "star")
      vote_fixture(play_fixture(tolerated), voter, "dope")
      vote_fixture(play_fixture(tolerated), voter, "dope")

      assert %{display_name: "Liked DJ", user_name: "liked", stars: 1, dopes: 0, score: 4} =
               Play.favorite_dj(voter.id)
    end

    test "the user's own plays don't count as their favorite DJ" do
      voter = user_fixture()
      other = user_fixture(%{user_name: "other"})

      # Self-votes on far more of their own plays than anyone else's.
      for _ <- 1..5, do: vote_fixture(play_fixture(voter), voter, "star")
      vote_fixture(play_fixture(other), voter, "dope")

      assert %{user_name: "other", score: 1} = Play.favorite_dj(voter.id)
    end

    test "returns nil when the only votes cast were on their own plays" do
      voter = user_fixture()
      vote_fixture(play_fixture(voter), voter, "star")

      assert Play.favorite_dj(voter.id) == nil
    end

    test "ignores votes other listeners cast" do
      voter = user_fixture()
      someone_else = user_fixture()
      dj = user_fixture(%{user_name: "dj"})
      loud_dj = user_fixture(%{user_name: "loud"})

      vote_fixture(play_fixture(dj), voter, "dope")
      for _ <- 1..5, do: vote_fixture(play_fixture(loud_dj), someone_else, "star")

      assert %{user_name: "dj"} = Play.favorite_dj(voter.id)
    end

    test "ignores non-scoring vote types" do
      voter = user_fixture()
      dj = user_fixture()
      vote_fixture(play_fixture(dj), voter, "nope")

      assert Play.favorite_dj(voter.id) == nil
    end
  end

  describe "favorite_track/1" do
    test "returns nil when the user has never voted" do
      assert Play.favorite_track(user_fixture().id) == nil
    end

    test "sums the points given across separate plays of the same track" do
      voter = user_fixture()
      dj = user_fixture()
      other_dj = user_fixture()

      repeat = fn user ->
        play_fixture(user, %{
          spotify_track_id: "repeat",
          track_name: "On Repeat",
          artist_names: ["A"]
        })
      end

      vote_fixture(repeat.(dj), voter, "dope")
      vote_fixture(repeat.(other_dj), voter, "dope")
      vote_fixture(play_fixture(dj, %{track_name: "Just Once"}), voter, "dope")

      assert %{track_name: "On Repeat", dopes: 2, score: 2} = Play.favorite_track(voter.id)
    end

    test "doesn't count the user's own plays" do
      voter = user_fixture()
      dj = user_fixture()

      vote_fixture(play_fixture(voter, %{track_name: "Mine"}), voter, "star")
      vote_fixture(play_fixture(dj, %{track_name: "Theirs"}), voter, "dope")

      assert %{track_name: "Theirs"} = Play.favorite_track(voter.id)
    end
  end

  describe "favorite_artist/1" do
    test "returns nil when the user has never voted" do
      assert Play.favorite_artist(user_fixture().id) == nil
    end

    test "credits every artist on a play the user voted on" do
      voter = user_fixture()
      dj = user_fixture()

      vote_fixture(play_fixture(dj, %{artist_names: ["Both", "Solo"]}), voter, "dope")
      vote_fixture(play_fixture(dj, %{artist_names: ["Both"]}), voter, "dope")

      assert %{artist_name: "Both", score: 2} = Play.favorite_artist(voter.id)
    end

    test "weights a star above a dope" do
      voter = user_fixture()
      dj = user_fixture()

      vote_fixture(play_fixture(dj, %{artist_names: ["Starred"]}), voter, "star")
      for _ <- 1..3, do: vote_fixture(play_fixture(dj, %{artist_names: ["Doped"]}), voter, "dope")

      assert %{artist_name: "Starred", score: 4} = Play.favorite_artist(voter.id)
    end
  end

  describe "stats_for/1" do
    test "is all zeroes and nils for a user who's never been in the room" do
      assert %{
               play_count: 0,
               dopes_received: 0,
               stars_received: 0,
               most_played: nil,
               best_play: nil,
               most_played_artist: nil,
               best_artist: nil,
               favorite_dj: nil,
               favorite_track: nil,
               favorite_artist: nil
             } = Play.stats_for(user_fixture().id)
    end

    test "counts the votes received across all of the user's plays" do
      user = user_fixture()
      first = play_fixture(user)
      second = play_fixture(user)

      vote_fixture(first, user_fixture(), "dope")
      vote_fixture(first, user_fixture(), "star")
      vote_fixture(second, user_fixture(), "dope")
      # Somebody else's play, so it counts toward neither total.
      vote_fixture(play_fixture(user_fixture()), user_fixture(), "star")

      assert %{play_count: 2, dopes_received: 2, stars_received: 1} = Play.stats_for(user.id)
    end
  end

  describe "average_durations/1" do
    test "averages each user's timed plays" do
      one = user_fixture()
      two = user_fixture()

      play_fixture(one, %{duration_ms: 100_000})
      play_fixture(one, %{duration_ms: 200_000})
      play_fixture(two, %{duration_ms: 300_000})

      result = Play.average_durations([one.id, two.id])

      assert result[one.id] == %{avg_ms: 150_000, play_count: 2}
      assert result[two.id] == %{avg_ms: 300_000, play_count: 1}
    end

    test "leaves out users with no timed plays entirely" do
      timed = user_fixture()
      untimed = user_fixture()
      never_played = user_fixture()

      play_fixture(timed, %{duration_ms: 210_000})
      play_fixture(untimed, %{duration_ms: nil})

      result = Play.average_durations([timed.id, untimed.id, never_played.id])

      assert Map.keys(result) == [timed.id]
      assert result[timed.id] == %{avg_ms: 210_000, play_count: 1}
    end

    test "rounds a fractional average to whole milliseconds" do
      user = user_fixture()
      play_fixture(user, %{duration_ms: 100_000})
      play_fixture(user, %{duration_ms: 100_001})

      assert %{avg_ms: avg_ms} = Play.average_durations([user.id])[user.id]
      assert is_integer(avg_ms)
      assert avg_ms in [100_000, 100_001]
    end

    test "returns an empty map for no user ids" do
      assert Play.average_durations([]) == %{}
    end
  end

  describe "average_duration/0" do
    test "is nil when nothing timed has been recorded" do
      play_fixture(user_fixture(), %{duration_ms: nil})

      assert Play.average_duration() == nil
    end

    test "averages across every DJ's timed plays" do
      play_fixture(user_fixture(), %{duration_ms: 100_000})
      play_fixture(user_fixture(), %{duration_ms: 200_000})
      play_fixture(user_fixture(), %{duration_ms: nil})

      assert Play.average_duration() == 150_000
    end
  end
end
