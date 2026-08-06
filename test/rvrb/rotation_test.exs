defmodule Rvrb.RotationTest do
  use ExUnit.Case, async: true

  alias Rvrb.Rotation

  @minute 60_000

  defp averages(pairs) do
    Map.new(pairs, fn {dj, {avg_ms, play_count}} ->
      {dj, %{avg_ms: avg_ms, play_count: play_count}}
    end)
  end

  describe "estimate/3" do
    test "returns an empty rotation for an empty queue" do
      assert Rotation.estimate([], %{}) == %{entries: [], total_ms: 0}
    end

    test "sums the queue's average track lengths into one lap" do
      estimate =
        Rotation.estimate(
          ["a", "b", "c"],
          averages(%{"a" => {3 * @minute, 5}, "b" => {4 * @minute, 2}, "c" => {5 * @minute, 9}})
        )

      assert estimate.total_ms == 12 * @minute
    end

    test "falls back for DJs with no history, and says so" do
      estimate =
        Rotation.estimate(["a", "newbie"], averages(%{"a" => {3 * @minute, 5}}),
          fallback_ms: 4 * @minute
        )

      assert [%{dj: "a", measured?: true, play_count: 5}, newbie] = estimate.entries
      assert newbie.duration_ms == 4 * @minute
      assert newbie.measured? == false
      assert newbie.play_count == 0
      assert estimate.total_ms == 7 * @minute
    end

    test "falls back to the default when there's no room average either" do
      estimate = Rotation.estimate(["a"], %{}, fallback_ms: nil)

      assert [%{duration_ms: duration_ms, measured?: false}] = estimate.entries
      assert duration_ms == Rotation.default_duration_ms()
    end

    test "treats an average of zero as no average at all" do
      estimate = Rotation.estimate(["a"], averages(%{"a" => {0, 3}}), fallback_ms: 4 * @minute)

      assert [%{duration_ms: duration_ms, measured?: false}] = estimate.entries
      assert duration_ms == 4 * @minute
    end

    test "counts the queue ahead of each DJ, starting from the current track's remainder" do
      estimate =
        Rotation.estimate(
          ["a", "b", "c"],
          averages(%{"a" => {3 * @minute, 5}, "b" => {4 * @minute, 2}, "c" => {5 * @minute, 9}}),
          remaining_ms: @minute
        )

      assert [current, b, c] = estimate.entries
      # b is up as soon as the current track ends
      assert b.wait_ms == @minute
      # c waits out the current track plus b's set
      assert c.wait_ms == @minute + 4 * @minute
      # the current DJ plays again only once the whole queue has been round
      assert current.current? == true
      assert current.wait_ms == @minute + 4 * @minute + 5 * @minute
    end

    test "assumes the current DJ's average is left when the remainder is unknown" do
      estimate =
        Rotation.estimate(
          ["a", "b"],
          averages(%{"a" => {3 * @minute, 5}, "b" => {4 * @minute, 2}})
        )

      assert [current, b] = estimate.entries
      assert b.wait_ms == 3 * @minute
      assert current.wait_ms == 3 * @minute + 4 * @minute
    end

    test "clamps a negative remainder - an overrunning track is 'about to end'" do
      estimate =
        Rotation.estimate(["a", "b"], averages(%{"a" => {3 * @minute, 5}}), remaining_ms: -5000)

      assert [_current, b] = estimate.entries
      assert b.wait_ms == 0
    end

    test "the only DJ in the queue waits out their own track before playing again" do
      estimate =
        Rotation.estimate(["a"], averages(%{"a" => {3 * @minute, 5}}), remaining_ms: 30_000)

      assert [%{current?: true, wait_ms: 30_000}] = estimate.entries
      assert estimate.total_ms == 3 * @minute
    end
  end

  describe "entry_for/2" do
    test "finds a DJ's entry and ignores everyone else's" do
      estimate = Rotation.estimate(["a", "b"], %{}, fallback_ms: 4 * @minute)

      assert %{dj: "b", wait_ms: wait_ms} = Rotation.entry_for(estimate, "b")
      assert wait_ms == 4 * @minute
    end

    test "returns nil for someone who isn't in the queue" do
      estimate = Rotation.estimate(["a"], %{})

      assert Rotation.entry_for(estimate, "listener") == nil
      assert Rotation.entry_for(estimate, nil) == nil
    end
  end

  describe "format_ms/1" do
    test "renders seconds, minutes and hours" do
      assert Rotation.format_ms(42_000) == "42s"
      assert Rotation.format_ms(200_000) == "3m 20s"
      assert Rotation.format_ms(3_840_000) == "1h 4m"
    end

    test "renders unknown and negative durations" do
      assert Rotation.format_ms(nil) == "?"
      assert Rotation.format_ms(-1000) == "0s"
      assert Rotation.format_ms(0) == "0s"
    end
  end
end
