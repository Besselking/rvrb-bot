defmodule Rvrb.PlayWriterTest do
  use Rvrb.DataCase, async: true

  import ExUnit.CaptureIO

  alias Rvrb.Play
  alias Rvrb.PlayVote
  alias Rvrb.PlayWriter

  setup do
    # Anonymous rather than the supervised, name-registered instance: this
    # one has to be handed the test's sandbox connection, and two async
    # tests can't share a name.
    writer = start_supervised!({PlayWriter, name: nil})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), writer)

    %{writer: writer, dj: user_fixture(), listener: user_fixture()}
  end

  defp track(name \\ "Track"), do: %{"id" => "spotify-1", "name" => name, "duration_ms" => 1000}

  defp votes(play_id) do
    from(v in PlayVote, where: v.play_id == ^play_id, select: {v.voter_user_id, v.vote_type})
    |> Repo.all()
    |> MapSet.new()
  end

  describe "record/3" do
    test "returns before the insert has happened", %{writer: writer, dj: dj} do
      assert :ok = PlayWriter.record(writer, [dj.rvrb_id], track())
    end

    test "records the play and points votes at it", %{writer: writer, dj: dj} do
      PlayWriter.record(writer, [dj.rvrb_id], track("Recorded"))

      play_id = PlayWriter.current_play_id(writer)

      assert %Play{track_name: "Recorded", user_id: dj_id} = Repo.get(Play, play_id)
      assert dj_id == dj.id
    end

    test "leaves nothing to attribute votes to when there's no DJ", %{writer: writer} do
      PlayWriter.record(writer, [], track())

      assert PlayWriter.current_play_id(writer) == nil
    end

    test "leaves nothing to attribute votes to when the DJ isn't a known user", %{writer: writer} do
      PlayWriter.record(writer, ["never-seen-this-one"], track())

      assert PlayWriter.current_play_id(writer) == nil
    end
  end

  describe "sync_votes/2" do
    test "writes the room's votes against the play recorded before them", %{
      writer: writer,
      dj: dj,
      listener: listener
    } do
      PlayWriter.record(writer, [dj.rvrb_id], track())
      PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"dope" => 1, "star" => 1}})

      play_id = PlayWriter.current_play_id(writer)

      assert votes(play_id) == MapSet.new([{listener.id, "dope"}, {listener.id, "star"}])
    end

    test "applies meters in the order they were cast", %{
      writer: writer,
      dj: dj,
      listener: listener
    } do
      PlayWriter.record(writer, [dj.rvrb_id], track())

      PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"dope" => 1}})
      PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"dope" => 1, "star" => 1}})
      PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"star" => 1}})

      play_id = PlayWriter.current_play_id(writer)

      assert votes(play_id) == MapSet.new([{listener.id, "star"}])
    end

    test "a meter cast after a track change lands on the new play", %{
      writer: writer,
      dj: dj,
      listener: listener
    } do
      PlayWriter.record(writer, [dj.rvrb_id], track("First"))
      PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"dope" => 1}})
      first_play_id = PlayWriter.current_play_id(writer)

      PlayWriter.record(writer, [dj.rvrb_id], track("Second"))
      PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"star" => 1}})
      second_play_id = PlayWriter.current_play_id(writer)

      refute first_play_id == second_play_id
      assert votes(first_play_id) == MapSet.new([{listener.id, "dope"}])
      assert votes(second_play_id) == MapSet.new([{listener.id, "star"}])
    end

    test "drops a meter that arrives with no play recorded", %{
      writer: writer,
      listener: listener
    } do
      PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"dope" => 1}})

      assert PlayWriter.current_play_id(writer) == nil
      assert Repo.aggregate(PlayVote, :count) == 0
    end
  end

  describe "failures" do
    test "a failing write doesn't take the writer (or the current play) down with it", %{
      writer: writer,
      dj: dj,
      listener: listener
    } do
      PlayWriter.record(writer, [dj.rvrb_id], track())
      play_id = PlayWriter.current_play_id(writer)

      output =
        capture_io(fn ->
          # The writer prints from its own process, which kept the real
          # group leader when it started - point it at the capture device.
          Process.group_leader(writer, Process.group_leader())

          # Not a meter payload at all - stands in for anything that makes a
          # write blow up, which must not cost us the rest of the track.
          PlayWriter.sync_votes(writer, "not a voting map")
          PlayWriter.sync_votes(writer, %{listener.rvrb_id => %{"dope" => 1}})
          assert PlayWriter.current_play_id(writer) == play_id
        end)

      assert output =~ "PlayWriter sync_votes failed"
      assert Process.alive?(writer)
      assert votes(play_id) == MapSet.new([{listener.id, "dope"}])
    end
  end
end
