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

  describe "releases_since/2 and releases_before/2" do
    @albums [
      %{"release_date" => "2024-01-01"},
      %{"release_date" => "2025-06-01"},
      %{"release_date" => "2023-12-31"},
      %{"release_date" => "2020-01-01"},
      %{"release_date" => "unknown"}
    ]

    test "releases_since counts only albums at or after the given year" do
      assert AiAnalyzer.releases_since(@albums, 2024) == 2
    end

    test "releases_before counts only albums strictly before the given year" do
      assert AiAnalyzer.releases_before(@albums, 2024) == 2
    end

    test "releases with an unknown date count toward neither" do
      albums = [%{"release_date" => "garbage"}]
      assert AiAnalyzer.releases_since(albums, 2024) == 0
      assert AiAnalyzer.releases_before(albums, 2024) == 0
    end

    test "both return 0 for an empty list" do
      assert AiAnalyzer.releases_since([], 2024) == 0
      assert AiAnalyzer.releases_before([], 2024) == 0
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
    test "is nil with no prior releases to form a baseline" do
      assert AiAnalyzer.cadence_ratio(0, nil, 30, 2026) == nil
      assert AiAnalyzer.cadence_ratio(0, 2024, 30, 2026) == nil
    end

    test "is nil when there's no earliest year even if prior_count is somehow set" do
      assert AiAnalyzer.cadence_ratio(3, nil, 30, 2026) == nil
    end

    test "is roughly 1 for a steady release pace" do
      # 3 releases/year for 4 years before 2024, then 3 releases/year for 3 years since
      ratio = AiAnalyzer.cadence_ratio(12, 2020, 9, 2026)
      assert_in_delta ratio, 1.0, 0.05
    end

    test "is high when recent cadence surges far past the prior baseline" do
      # 1 release/year for 4 years before 2024, then 30 releases over 3 years since
      ratio = AiAnalyzer.cadence_ratio(4, 2020, 30, 2026)
      assert ratio > 4
    end

    test "is low when recent cadence drops well below the prior baseline" do
      # 10 releases/year for 4 years before 2024, then 1 release over 3 years since
      ratio = AiAnalyzer.cadence_ratio(40, 2020, 1, 2026)
      assert ratio < 0.1
    end
  end

  describe "verdict/3" do
    test "flags a brand new artist with a high release count as likely AI spam" do
      assert %{level: :likely} = AiAnalyzer.verdict(30, 0, nil)
    end

    test "flags moderate release volume with no baseline as worth a second look" do
      assert %{level: :possible} = AiAnalyzer.verdict(10, 0, nil)
    end

    test "treats low release volume as normal" do
      assert %{level: :unlikely} = AiAnalyzer.verdict(2, 0, nil)
    end

    test "escalates when a high release count also represents a cadence surge" do
      # base level would be :possible at 10, but a 5x cadence surge bumps it up
      assert %{level: :likely} = AiAnalyzer.verdict(10, 2, 5.0)
    end

    test "de-escalates a high release count when it matches a long-standing steady pace" do
      # base level would be :likely at 25, but matching their usual cadence dampens it
      assert %{level: :possible} = AiAnalyzer.verdict(25, 25, 1.0)
    end

    test "never escalates past :likely or de-escalates past :unlikely" do
      assert %{level: :likely} = AiAnalyzer.verdict(25, 1, 100.0)
      assert %{level: :unlikely} = AiAnalyzer.verdict(1, 25, 0.01)
    end

    test "label mentions the release count" do
      assert %{label: label} = AiAnalyzer.verdict(30, 0, nil)
      assert label =~ "30"
    end

    test "label notes when the artist has no releases before the cutoff" do
      assert %{label: label} = AiAnalyzer.verdict(30, 0, nil)
      assert label =~ "none before"
    end

    test "label mentions the cadence multiplier when a baseline exists" do
      assert %{label: label} = AiAnalyzer.verdict(10, 2, 5.0)
      assert label =~ "5.0x"
    end
  end
end
