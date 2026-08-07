defmodule Rvrb.WebSocketTest do
  @moduledoc """
  Regression tests for the two message handlers that used to raise a
  `MatchError` on entirely ordinary server pushes, dropping the bot off
  the socket along with its queue and DJ state.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Rvrb.WebSocket

  describe "nextChannelTrack" do
    test "answers the RPC with an error when the queue is empty" do
      state = %{queue: []}

      assert {:reply, {:text, frame}, ^state} =
               handle(%{"method" => "nextChannelTrack", "id" => 7}, state)

      response = JSON.decode!(frame)

      assert response["id"] == 7
      assert response["error"]["message"] =~ "no tracks queued"
      refute Map.has_key?(response, "result")
    end

    test "hands over the head of the queue when there is one" do
      state = %{queue: [%{"name" => "Alpha"}, %{"name" => "Beta"}]}

      assert {:reply, {:text, frame}, new_state} =
               handle(%{"method" => "nextChannelTrack", "id" => 7}, state)

      assert JSON.decode!(frame)["result"]["track"] == %{"name" => "Alpha"}
      assert new_state.queue == [%{"name" => "Beta"}]
    end
  end

  describe "updateChannelMeter" do
    test "handles a meter that arrives with no DJs at all" do
      state = %{djs: [], doped: false, starred: false, current_play_id: nil}

      assert {:ok, %{doped: false, starred: false}} =
               handle(
                 %{"method" => "updateChannelMeter", "params" => %{"voting" => %{}}},
                 state
               )
    end

    test "still doesn't auto-vote when the only DJ is the one playing" do
      state = %{djs: ["dj-a"], doped: false, starred: false, current_play_id: nil}

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

  defp handle(message, state) do
    capture_io(fn -> send(self(), {:handled, WebSocket.handle_message(message, state)}) end)

    assert_received {:handled, result}
    result
  end
end
