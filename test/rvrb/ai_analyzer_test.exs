defmodule Rvrb.AiAnalyzerTest do
  use ExUnit.Case, async: true

  alias Rvrb.AiAnalyzer

  describe "release_year/1" do
    test "parses full dates" do
      assert AiAnalyzer.release_year("2024-03-15") == 2024
    end

    test "parses year-month precision" do
      assert AiAnalyzer.release_year("2023-11") == 2023
    end

    test "parses year-only precision" do
      assert AiAnalyzer.release_year("1999") == 1999
    end

    test "treats missing/invalid dates as year 0" do
      assert AiAnalyzer.release_year(nil) == 0
      assert AiAnalyzer.release_year("") == 0
      assert AiAnalyzer.release_year("unknown") == 0
    end
  end

  describe "release_score/1" do
    test "uses total_tracks when present" do
      assert AiAnalyzer.release_score(%{"total_tracks" => 5}) == 5
    end

    test "caps at the max tracks per release so one big drop can't dominate" do
      assert AiAnalyzer.release_score(%{"total_tracks" => 40}) == 12
    end

    test "defaults to 1 when total_tracks is missing or invalid" do
      assert AiAnalyzer.release_score(%{}) == 1
      assert AiAnalyzer.release_score(%{"total_tracks" => nil}) == 1
      assert AiAnalyzer.release_score(%{"total_tracks" => 0}) == 1
    end
  end

  describe "release_summary/2" do
    @albums [
      %{"release_date" => "2024-01-01", "album_type" => "single", "total_tracks" => 1},
      %{"release_date" => "2025-06-01", "album_type" => "album", "total_tracks" => 10},
      %{"release_date" => "2023-12-31", "album_type" => "single", "total_tracks" => 1},
      %{"release_date" => "2020-01-01", "album_type" => "album", "total_tracks" => 8},
      %{"release_date" => "garbage", "album_type" => "single", "total_tracks" => 1}
    ]

    test "counts and scores only releases matching the year filter" do
      summary = AiAnalyzer.release_summary(@albums, &(&1 >= 2024))
      assert summary.count == 2
      assert summary.albums == 1
      assert summary.singles == 1
      assert summary.track_score == 11
    end

    test "a release with an unknown date falls into neither a since- nor a before-cutoff bucket" do
      since_summary = AiAnalyzer.release_summary(@albums, &(&1 >= 2024))
      before_summary = AiAnalyzer.release_summary(@albums, &(&1 > 0 and &1 < 2024))

      assert since_summary.count == 2
      assert before_summary.count == 2
      assert since_summary.count + before_summary.count == length(@albums) - 1
    end

    test "a bunch of one-track singles scores much lower than a couple of albums" do
      singles = for _ <- 1..9, do: %{"release_date" => "2024-01-01", "album_type" => "single", "total_tracks" => 1}
      albums = for _ <- 1..3, do: %{"release_date" => "2024-01-01", "album_type" => "album", "total_tracks" => 10}

      singles_summary = AiAnalyzer.release_summary(singles, &(&1 >= 2024))
      albums_summary = AiAnalyzer.release_summary(albums, &(&1 >= 2024))

      assert singles_summary.track_score == 9
      assert albums_summary.track_score == 30
      assert singles_summary.track_score < albums_summary.track_score
    end

    test "returns zeroes for an empty list" do
      summary = AiAnalyzer.release_summary([], &(&1 >= 2024))
      assert summary == %{count: 0, albums: 0, singles: 0, track_score: 0}
    end
  end

  describe "earliest_release_year/1" do
    test "returns the minimum known release year" do
      albums = [%{"release_date" => "2022-01-01"}, %{"release_date" => "2019-06-01"}]
      assert AiAnalyzer.earliest_release_year(albums) == 2019
    end

    test "ignores unknown dates" do
      albums = [%{"release_date" => "garbage"}, %{"release_date" => "2021-01-01"}]
      assert AiAnalyzer.earliest_release_year(albums) == 2021
    end

    test "returns nil when there's no usable date" do
      assert AiAnalyzer.earliest_release_year([]) == nil
      assert AiAnalyzer.earliest_release_year([%{"release_date" => "garbage"}]) == nil
    end
  end

  describe "cadence_ratio/4" do
    test "is nil with no prior release volume to form a baseline" do
      assert AiAnalyzer.cadence_ratio(0, nil, 30, 2026) == nil
      assert AiAnalyzer.cadence_ratio(0, 2024, 30, 2026) == nil
    end

    test "is nil when there's no earliest year even if prior_score is somehow set" do
      assert AiAnalyzer.cadence_ratio(3, nil, 30, 2026) == nil
    end

    test "is roughly 1 for a steady release pace" do
      # score 12 over 4 years before 2024, then score 9 over 3 years since
      ratio = AiAnalyzer.cadence_ratio(12, 2020, 9, 2026)
      assert_in_delta ratio, 1.0, 0.05
    end

    test "is high when recent cadence surges far past the prior baseline" do
      ratio = AiAnalyzer.cadence_ratio(4, 2020, 30, 2026)
      assert ratio > 4
    end

    test "is low when recent cadence drops well below the prior baseline" do
      ratio = AiAnalyzer.cadence_ratio(40, 2020, 1, 2026)
      assert ratio < 0.1
    end
  end

  describe "verdict/3" do
    test "9 one-track singles since the cutoff (and none before) looks normal" do
      recent = AiAnalyzer.release_summary(
        for(_ <- 1..9, do: %{"release_date" => "2024-06-01", "album_type" => "single", "total_tracks" => 1}),
        &(&1 >= 2024)
      )

      prior = %{count: 0, albums: 0, singles: 0, track_score: 0}

      assert %{level: :unlikely, label: label} = AiAnalyzer.verdict(recent, prior, nil)
      assert label =~ "9 singles"
      assert label =~ "none before"
    end

    test "a handful of full albums with no prior history is at least worth a second look" do
      recent = AiAnalyzer.release_summary(
        for(_ <- 1..4, do: %{"release_date" => "2024-06-01", "album_type" => "album", "total_tracks" => 10}),
        &(&1 >= 2024)
      )

      prior = %{count: 0, albums: 0, singles: 0, track_score: 0}

      assert %{level: level} = AiAnalyzer.verdict(recent, prior, nil)
      assert level in [:possible, :likely]
    end

    test "escalates when high volume also represents a cadence surge" do
      recent = %{count: 10, albums: 1, singles: 9, track_score: 18}
      prior = %{count: 2, albums: 0, singles: 2, track_score: 2}

      assert %{level: :possible} = AiAnalyzer.verdict(recent, prior, 5.0)
    end

    test "de-escalates high volume that matches a long-standing steady pace" do
      recent = %{count: 5, albums: 4, singles: 1, track_score: 41}
      prior = %{count: 5, albums: 4, singles: 1, track_score: 41}

      assert %{level: :unlikely} = AiAnalyzer.verdict(recent, prior, 1.0)
    end

    test "never escalates past :likely or de-escalates past :unlikely" do
      recent = %{count: 5, albums: 4, singles: 1, track_score: 41}
      prior = %{count: 1, albums: 0, singles: 1, track_score: 1}
      assert %{level: :likely} = AiAnalyzer.verdict(recent, prior, 100.0)

      recent0 = %{count: 1, albums: 0, singles: 1, track_score: 1}
      prior0 = %{count: 5, albums: 4, singles: 1, track_score: 41}
      assert %{level: :unlikely} = AiAnalyzer.verdict(recent0, prior0, 0.01)
    end
  end
end
