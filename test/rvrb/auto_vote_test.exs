defmodule Rvrb.AutoVoteTest do
  @moduledoc """
  The auto-vote decision table: when a unanimous DJ queue is worth joining,
  when a vote already cast has to be taken back, and what counts as a DJ
  whose vote matters.
  """

  use ExUnit.Case, async: true

  alias Rvrb.AutoVote

  describe "deciding_djs/2" do
    test "drops whoever is playing right now" do
      assert AutoVote.deciding_djs(["dj-a", "dj-b", "dj-c"]) == ["dj-b", "dj-c"]
    end

    test "drops bots, including this one, wherever they sit in the queue" do
      bots = MapSet.new(["bot-self", "bot-other"])

      assert AutoVote.deciding_djs(["dj-a", "bot-self", "dj-b", "bot-other"], bots) == ["dj-b"]
    end

    test "handles an empty queue" do
      assert AutoVote.deciding_djs([]) == []
    end
  end

  describe "decide/3 with no vote cast" do
    test "votes once two queued DJs agree" do
      assert AutoVote.decide(false, ["dj-b", "dj-c"], ["dj-b", "dj-c"]) == :vote
    end

    test "holds on a single queued DJ, however keen they are" do
      assert AutoVote.decide(false, ["dj-b"], ["dj-b"]) == :hold
    end

    test "holds while one of the queued DJs hasn't voted" do
      assert AutoVote.decide(false, ["dj-b", "dj-c"], ["dj-b", "dj-c", "dj-d"]) == :hold
    end

    test "holds with nobody queued behind the decks" do
      assert AutoVote.decide(false, ["dj-b"], []) == :hold
    end
  end

  describe "decide/3 with a vote already cast" do
    test "holds while the queue still agrees" do
      assert AutoVote.decide(true, ["dj-b", "dj-c"], ["dj-b", "dj-c"]) == :hold
    end

    test "retracts once a DJ who hasn't voted joins the queue" do
      assert AutoVote.decide(true, ["dj-b", "dj-c"], ["dj-b", "dj-c", "dj-d"]) == :retract
    end

    test "retracts when a voter takes their own vote back" do
      assert AutoVote.decide(true, ["dj-b"], ["dj-b", "dj-c"]) == :retract
    end

    # The two-DJ floor only gates starting a vote - once the room has
    # spoken, DJs dropping out of the queue don't unsay it.
    test "keeps the vote when the queue shrinks to a single agreeing DJ" do
      assert AutoVote.decide(true, ["dj-b", "dj-c"], ["dj-b"]) == :hold
    end

    test "keeps the vote when the queue empties out entirely" do
      assert AutoVote.decide(true, ["dj-b", "dj-c"], []) == :hold
    end

    test "retracts when the one DJ left never voted" do
      assert AutoVote.decide(true, ["dj-b"], ["dj-d"]) == :retract
    end
  end

  describe "voters/2" do
    test "picks out who cast the vote type asked for" do
      voting = %{
        "dj-a" => %{"dope" => 1, "star" => 0},
        "dj-b" => %{"dope" => 1, "star" => 1},
        "dj-c" => %{"dope" => 0, "star" => 0}
      }

      assert Enum.sort(AutoVote.voters(voting, "dope")) == ["dj-a", "dj-b"]
      assert AutoVote.voters(voting, "star") == ["dj-b"]
    end

    # `nil > 0` is true under Elixir's term ordering, so a meter that leaves
    # the key out used to read as a vote for it.
    test "treats a missing vote type as no vote" do
      assert AutoVote.voters(%{"dj-a" => %{"dope" => 1}}, "star") == []
    end
  end

  describe "bot_ids/1" do
    test "picks out the users RVRB marks as bots" do
      users = [
        %{"_id" => "user-1", "userName" => "Bess"},
        %{"_id" => "bot-1", "userName" => "bot_1728728144538", "type" => "bot"}
      ]

      assert AutoVote.bot_ids(users) == MapSet.new(["bot-1"])
    end
  end
end
