defmodule Rvrb.DjRestoreTest do
  use ExUnit.Case, async: true

  alias Rvrb.DjRestore

  @window DjRestore.window_ms()

  # A queue of A..E, with C (third in line, index 2) dropping out.
  @queue ~w[a b c d e]
  @without_c ~w[a b d e]

  defp drop_c(plays \\ 0, now \\ 0) do
    {dropped, @without_c} = DjRestore.update(%{}, @queue, @without_c, plays, now)
    dropped
  end

  describe "target/2" do
    test "keeps the absolute spot while no track has played" do
      assert DjRestore.target(%{position: 2, plays: 0, at: 0}, 0) == 2
    end

    test "moves up a spot for every track played since" do
      assert DjRestore.target(%{position: 4, plays: 3, at: 0}, 4) == 3
      assert DjRestore.target(%{position: 4, plays: 3, at: 0}, 5) == 2
      assert DjRestore.target(%{position: 4, plays: 3, at: 0}, 6) == 1
    end

    test "goes next up rather than to the playing spot" do
      assert DjRestore.target(%{position: 2, plays: 0, at: 0}, 2) == 1
    end

    test "falls back to the absolute spot once the relative one has come round" do
      assert DjRestore.target(%{position: 2, plays: 0, at: 0}, 3) == 2
      assert DjRestore.target(%{position: 2, plays: 0, at: 0}, 10) == 2
    end

    test "never gives the playing spot, even to a DJ who dropped from it" do
      assert DjRestore.target(%{position: 0, plays: 0, at: 0}, 0) == 1
      assert DjRestore.target(%{position: 0, plays: 0, at: 0}, 4) == 1
    end
  end

  describe "moves/3" do
    test "lists who was moved, with the spot they went to" do
      assert DjRestore.moves(~w[a b d e], ~w[a b d e c], ~w[a b c d e]) == [{"c", 2}]
    end

    test "leaves out a DJ who stayed at the back" do
      assert DjRestore.moves(~w[a], ~w[a c], ~w[a c]) == []
      assert DjRestore.moves(~w[a b], ~w[a b c], ~w[a b c]) == []
    end

    test "leaves out DJs who were already in the queue" do
      assert DjRestore.moves(~w[a b], ~w[b a], ~w[b a]) == []
    end

    test "lists every DJ who was moved" do
      assert DjRestore.moves(~w[a c e], ~w[a c e b d], ~w[a b c d e]) == [{"b", 1}, {"d", 3}]
    end
  end

  describe "update/6" do
    test "records who dropped and from where" do
      assert %{"c" => %{position: 2, plays: 0, at: 5}} = drop_c(0, 5)
    end

    test "puts a returning DJ back in their absolute spot" do
      assert {dropped, ~w[a b c d e]} =
               DjRestore.update(drop_c(), @without_c, ~w[a b d e c], 0, 1_000)

      assert dropped == %{}
    end

    test "moves them up for the tracks that played while they were away" do
      # One play: the queue rotated a to the back, so c is next up.
      assert {_, ~w[b c d e a]} =
               DjRestore.update(drop_c(), ~w[b d e a], ~w[b d e a c], 1, 1_000)
    end

    test "uses the absolute spot when the relative one has gone round" do
      # Three plays: c's turn came and went while they were away.
      assert {_, ~w[d e c a b]} =
               DjRestore.update(drop_c(), ~w[d e a b], ~w[d e a b c], 3, 1_000)
    end

    test "leaves a short queue alone when the spot is past its end" do
      dropped = drop_c()
      assert {_, ~w[a c]} = DjRestore.update(dropped, ~w[a], ~w[a c], 0, 1_000)
    end

    test "keeps a DJ who rejoins an empty queue at the front" do
      dropped = drop_c()
      assert {_, ~w[c]} = DjRestore.update(dropped, [], ~w[c], 0, 1_000)
    end

    test "restores a DJ that comes back exactly at the end of the window" do
      assert {_, ~w[a b c d e]} =
               DjRestore.update(drop_c(), @without_c, ~w[a b d e c], 0, @window)
    end

    test "does not restore a DJ that comes back after the window" do
      assert {dropped, ~w[a b d e c]} =
               DjRestore.update(drop_c(), @without_c, ~w[a b d e c], 0, @window + 1)

      assert dropped == %{}
    end

    test "only restores a DJ once" do
      {dropped, _} = DjRestore.update(drop_c(), @without_c, ~w[a b d e c], 0, 1_000)
      {dropped, _} = DjRestore.update(dropped, ~w[a b c d e], ~w[a b d e], 0, 2_000)
      assert %{"c" => _} = dropped
    end

    test "forgets a DJ nobody saw come back, once the window is up" do
      assert {dropped, _} = DjRestore.update(drop_c(), @without_c, @without_c, 0, @window + 1)
      assert dropped == %{}
    end

    test "restores several DJs who return in one update" do
      # b dropped from 1, d from 3 - each back to their own spot.
      {dropped, _} = DjRestore.update(%{}, ~w[a b c d e], ~w[a c e], 0, 0)

      assert {%{}, ~w[a b c d e]} = DjRestore.update(dropped, ~w[a c e], ~w[a c e b d], 0, 1_000)
    end

    test "does not keep the spot of an ignored id" do
      assert {%{}, @without_c} =
               DjRestore.update(%{}, @queue, @without_c, 0, 0, MapSet.new(["c"]))
    end

    test "leaves a plain rotation or a new DJ alone" do
      assert {%{}, ~w[b c a]} = DjRestore.update(%{}, ~w[a b c], ~w[b c a], 1, 0)
      assert {%{}, ~w[a b c]} = DjRestore.update(%{}, ~w[a b], ~w[a b c], 0, 0)
    end
  end
end
