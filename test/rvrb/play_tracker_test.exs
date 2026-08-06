defmodule Rvrb.PlayTrackerTest do
  use ExUnit.Case, async: true

  alias Rvrb.PlayTracker

  describe "track_attrs/2" do
    test "pulls track/artist fields from a raw RVRB track payload" do
      track = %{
        "id" => "spotify-track-1",
        "name" => "Test Track",
        "artists" => [
          %{"id" => "artist-1", "name" => "Artist One"},
          %{"id" => "artist-2", "name" => "Artist Two"}
        ]
      }

      attrs = PlayTracker.track_attrs(track, 42)

      assert attrs.user_id == 42
      assert attrs.spotify_track_id == "spotify-track-1"
      assert attrs.track_name == "Test Track"
      assert attrs.artist_names == ["Artist One", "Artist Two"]
      assert attrs.spotify_artist_ids == ["artist-1", "artist-2"]
      assert %NaiveDateTime{} = attrs.played_at
    end

    test "tolerates a track with no artists list" do
      attrs = PlayTracker.track_attrs(%{"id" => "t1", "name" => "No Artists"}, 1)

      assert attrs.artist_names == []
      assert attrs.spotify_artist_ids == []
    end

    test "captures the track length, and leaves it nil when the payload has none" do
      assert PlayTracker.track_attrs(%{"name" => "T", "duration_ms" => 213_000}, 1).duration_ms ==
               213_000

      assert PlayTracker.track_attrs(%{"name" => "T"}, 1).duration_ms == nil
    end
  end

  describe "duration_ms/1" do
    test "reads Spotify's duration_ms" do
      assert PlayTracker.duration_ms(%{"duration_ms" => 213_000}) == 213_000
    end

    test "falls back to a bare duration in milliseconds" do
      assert PlayTracker.duration_ms(%{"duration" => 213_000}) == 213_000
    end

    test "reads a bare duration too small to be milliseconds as seconds" do
      assert PlayTracker.duration_ms(%{"duration" => 213}) == 213_000
    end

    test "rounds a fractional duration" do
      assert PlayTracker.duration_ms(%{"duration_ms" => 213_000.6}) == 213_001
    end

    test "returns nil for a missing, zero or non-numeric duration" do
      assert PlayTracker.duration_ms(%{}) == nil
      assert PlayTracker.duration_ms(%{"duration_ms" => 0}) == nil
      assert PlayTracker.duration_ms(%{"duration_ms" => "3:33"}) == nil
      assert PlayTracker.duration_ms(nil) == nil
    end
  end

  describe "desired_votes/2" do
    test "includes only positive-count votes for known voters" do
      voting = %{
        "user-a" => %{"dope" => 1, "star" => 0},
        "user-b" => %{"dope" => 0, "star" => 2, "boofstar" => 1}
      }

      voter_ids = %{"user-a" => 10, "user-b" => 20}

      assert PlayTracker.desired_votes(voting, voter_ids) ==
               MapSet.new([{10, "dope"}, {20, "star"}, {20, "boofstar"}])
    end

    test "drops voters with no known internal id" do
      voting = %{"unknown-user" => %{"dope" => 3}}

      assert PlayTracker.desired_votes(voting, %{}) == MapSet.new()
    end

    test "ignores unrecognized vote types" do
      voting = %{"user-a" => %{"totallymadeup" => 5}}
      voter_ids = %{"user-a" => 10}

      assert PlayTracker.desired_votes(voting, voter_ids) == MapSet.new()
    end

    test "returns an empty set for an empty voting map" do
      assert PlayTracker.desired_votes(%{}, %{}) == MapSet.new()
    end
  end

  describe "record/2" do
    test "returns nil immediately when there's no DJ" do
      assert PlayTracker.record([], %{"name" => "Track"}) == nil
    end
  end

  describe "sync_votes/2" do
    test "no-ops without hitting the database when play_id is nil" do
      assert PlayTracker.sync_votes(nil, %{"user-a" => %{"dope" => 1}}) == :ok
    end
  end
end
