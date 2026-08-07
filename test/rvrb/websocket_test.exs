defmodule Rvrb.WebSocketTest do
  @moduledoc """
  Tests for `Rvrb.WebSocket.handle_message/2`, covering the handlers that
  used to raise a `MatchError` on entirely ordinary server pushes -
  dropping the bot off the socket along with its queue and DJ state - and
  what each one leaves behind in the `%Rvrb.WebSocket.State{}` it carries.
  """

  use Rvrb.DataCase, async: false

  import ExUnit.CaptureLog

  alias Rvrb.WebSocket
  alias Rvrb.WebSocket.State

  describe "nextChannelTrack" do
    test "answers the RPC with an error when the queue is empty" do
      state = %State{queue: []}

      assert {:reply, {:text, frame}, ^state} =
               handle(%{"method" => "nextChannelTrack", "id" => 7}, state)

      response = JSON.decode!(frame)

      assert response["id"] == 7
      assert response["error"]["message"] =~ "no tracks queued"
      refute Map.has_key?(response, "result")
    end

    test "hands over the head of the queue when there is one" do
      state = %State{queue: [%{"name" => "Alpha"}, %{"name" => "Beta"}]}

      assert {:reply, {:text, frame}, new_state} =
               handle(%{"method" => "nextChannelTrack", "id" => 7}, state)

      assert JSON.decode!(frame)["result"]["track"] == %{"name" => "Alpha"}
      assert new_state.queue == [%{"name" => "Beta"}]
    end
  end

  describe "updateChannelMeter" do
    test "handles a meter that arrives with no DJs at all" do
      state = %State{djs: [], doped: false, starred: false}

      assert {:ok, %{doped: false, starred: false}} =
               handle(
                 %{"method" => "updateChannelMeter", "params" => %{"voting" => %{}}},
                 state
               )
    end

    test "still doesn't auto-vote when the only DJ is the one playing" do
      state = %State{djs: ["dj-a"], doped: false, starred: false}

      assert {:ok, %{doped: false, starred: false}} =
               handle(
                 %{
                   "method" => "updateChannelMeter",
                   "params" => %{"voting" => %{"dj-a" => %{"dope" => 1, "star" => 0}}}
                 },
                 state
               )
    end
  end

  describe "ready" do
    test "remembers the channel it joined" do
      assert {:reply, {:text, frame}, state} =
               handle(
                 %{"method" => "ready", "params" => %{"channelId" => "chan-1"}},
                 %State{}
               )

      assert JSON.decode!(frame)["params"]["channelId"] == "chan-1"
      assert state.channel_id == "chan-1"
    end
  end

  describe "playChannelTrack" do
    # There used to be a second clause ahead of this one, guarded on an
    # `:autodope` key nothing ever set, so it never ran. Every track goes
    # through the one clause: votes reset, start time stamped.
    test "clears the previous track's votes and stamps the start time" do
      state = %State{doped: true, starred: true, current_track_started_at: nil}
      track = %{"name" => "Alpha", "artist" => %{"name" => "Ada"}}

      assert {:ok, new_state} =
               handle(%{"method" => "playChannelTrack", "params" => %{"track" => track}}, state)

      refute new_state.doped
      refute new_state.starred
      assert new_state.current_track == track
      assert is_integer(new_state.current_track_started_at)
    end
  end

  defp handle(message, state) do
    capture_log(fn -> send(self(), {:handled, WebSocket.handle_message(message, state)}) end)

    assert_received {:handled, result}
    result
  end
end
