defmodule Rvrb.PlayVoteTest do
  use Rvrb.DataCase, async: true

  alias Rvrb.PlayVote

  setup do
    dj = user_fixture()
    %{play: play_fixture(dj), listener: user_fixture(), other_listener: user_fixture()}
  end

  defp recorded(play_id) do
    from(v in PlayVote, where: v.play_id == ^play_id, select: {v.voter_user_id, v.vote_type})
    |> Repo.all()
    |> MapSet.new()
  end

  describe "changeset/2" do
    test "rejects a vote type RVRB doesn't have", %{play: play, listener: listener} do
      changeset =
        PlayVote.changeset(%PlayVote{}, %{
          play_id: play.id,
          voter_user_id: listener.id,
          vote_type: "shrug"
        })

      assert %{vote_type: [_]} = errors_on(changeset)
    end
  end

  describe "sync/2" do
    test "inserts the votes that weren't there yet", %{play: play, listener: listener} do
      desired = MapSet.new([{listener.id, "dope"}, {listener.id, "star"}])

      assert :ok = PlayVote.sync(play.id, desired)
      assert recorded(play.id) == desired
    end

    test "deletes the votes a listener took back", %{
      play: play,
      listener: listener,
      other_listener: other
    } do
      PlayVote.sync(play.id, MapSet.new([{listener.id, "dope"}, {other.id, "dope"}]))

      assert :ok = PlayVote.sync(play.id, MapSet.new([{other.id, "dope"}]))
      assert recorded(play.id) == MapSet.new([{other.id, "dope"}])
    end

    test "deletes only the vote type that was taken back", %{play: play, listener: listener} do
      PlayVote.sync(play.id, MapSet.new([{listener.id, "dope"}, {listener.id, "star"}]))

      assert :ok = PlayVote.sync(play.id, MapSet.new([{listener.id, "star"}]))
      assert recorded(play.id) == MapSet.new([{listener.id, "star"}])
    end

    test "clears every vote when the meter comes back empty", %{play: play, listener: listener} do
      PlayVote.sync(play.id, MapSet.new([{listener.id, "dope"}]))

      assert :ok = PlayVote.sync(play.id, MapSet.new())
      assert recorded(play.id) == MapSet.new()
    end

    test "is idempotent - syncing the same state twice changes nothing", %{
      play: play,
      listener: listener
    } do
      desired = MapSet.new([{listener.id, "dope"}])

      PlayVote.sync(play.id, desired)

      ids_after_first =
        from(v in PlayVote, where: v.play_id == ^play.id, select: v.id) |> Repo.all()

      assert :ok = PlayVote.sync(play.id, desired)

      assert from(v in PlayVote, where: v.play_id == ^play.id, select: v.id) |> Repo.all() ==
               ids_after_first
    end

    test "leaves other plays' votes alone", %{play: play, listener: listener} do
      untouched = play_fixture(user_fixture())
      PlayVote.sync(untouched.id, MapSet.new([{listener.id, "star"}]))

      assert :ok = PlayVote.sync(play.id, MapSet.new([{listener.id, "dope"}]))

      assert recorded(untouched.id) == MapSet.new([{listener.id, "star"}])
      assert recorded(play.id) == MapSet.new([{listener.id, "dope"}])
    end

    test "a vote coming back after being taken back is inserted again", %{
      play: play,
      listener: listener
    } do
      desired = MapSet.new([{listener.id, "dope"}])

      PlayVote.sync(play.id, desired)
      PlayVote.sync(play.id, MapSet.new())
      assert :ok = PlayVote.sync(play.id, desired)

      assert recorded(play.id) == desired
    end
  end
end
