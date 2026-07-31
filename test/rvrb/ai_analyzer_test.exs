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

  describe "releases_since/2" do
    test "counts only albums at or after the given year" do
      albums = [
        %{release_date: "2024-01-01"},
        %{release_date: "2025-06-01"},
        %{release_date: "2023-12-31"},
        %{release_date: "2020-01-01"}
      ]

      assert AiAnalyzer.releases_since(albums, 2024) == 2
    end

    test "returns 0 for an empty list" do
      assert AiAnalyzer.releases_since([], 2024) == 0
    end
  end

  describe "verdict/1" do
    test "flags high release volume as likely AI spam" do
      assert %{level: :likely} = AiAnalyzer.verdict(20)
      assert %{level: :likely} = AiAnalyzer.verdict(50)
    end

    test "flags moderate release volume as possible" do
      assert %{level: :possible} = AiAnalyzer.verdict(8)
      assert %{level: :possible} = AiAnalyzer.verdict(19)
    end

    test "treats low release volume as normal" do
      assert %{level: :unlikely} = AiAnalyzer.verdict(0)
      assert %{level: :unlikely} = AiAnalyzer.verdict(7)
    end

    test "verdict label mentions the release count" do
      assert %{label: label} = AiAnalyzer.verdict(30)
      assert label =~ "30"
    end
  end
end
