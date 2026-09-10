defmodule Rvrb.CommandHandlersTest do
  @moduledoc """
  Regression tests for the command handlers that used to raise inside the
  websocket connection process, taking the connection (and everything it
  held - the track queue, the DJ list, the current track) down with it.

  The handlers talk to the socket through the `Rvrb.Socket` behaviour, so
  here they talk to a stub that forwards each call back to the test
  process instead of a live websocket.
  """

  use Rvrb.DataCase, async: false

  import ExUnit.CaptureLog

  alias Rvrb.Commands
  alias Rvrb.WebSocket.State

  defmodule SocketStub do
    @behaviour Rvrb.Socket

    @impl true
    def chat(message), do: send(self(), {:chat, message})

    @impl true
    def send_message(message), do: send(self(), {:send_message, message})

    @impl true
    def send_queue(queue), do: send(self(), {:send_queue, queue})

    @impl true
    def edit_user(params), do: send(self(), {:edit_user, params})
  end

  setup do
    # `\qg` calls into the GenreServer, which the application doesn't start
    # in test - see `Rvrb.Application.start/2`.
    start_supervised!({Rvrb.GenreServer, Application.app_dir(:rvrb, "priv/genres.txt")})

    previous = Application.get_env(:rvrb, :socket)
    Application.put_env(:rvrb, :socket, SocketStub)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:rvrb, :socket)
        module -> Application.put_env(:rvrb, :socket, module)
      end
    end)
  end

  describe "\\qg" do
    test "replies with a suggestion instead of crashing when nothing matches" do
      assert {:ok, _state} = handle("\\qg zzzzzzzzzz", %{}, %{})
      assert_received {:chat, message}
      assert message =~ "No genres matching \"zzzzzzzzzz\""
    end

    test "matches a keyword typed with capitals" do
      assert {:ok, _state} = handle("\\qg Rock", %{}, %{})
      assert_received {:chat, message}
      assert String.downcase(message) =~ "rock"
    end

    test "suggests a genre with no keyword at all" do
      assert {:ok, _state} = handle("\\qg", %{}, %{})
      assert_received {:chat, message}
      assert is_binary(message) and message != ""
    end
  end

  describe "\\spin" do
    test "says nothing is playing when no track has played yet" do
      assert {:ok, _state} = handle("\\spin", %{}, %State{})
      assert_received {:chat, "No track is currently playing."}
    end

    test "spins the current track's album art" do
      track = %{"album" => %{"images" => [%{"url" => "https://img/cover.jpg"}]}}

      assert {:ok, _state} = handle("\\spin", %{}, %State{current_track: track})
      assert_received {:chat, message}
      assert message =~ "https://img/cover.jpg"
      assert message =~ "circular spin"
    end
  end

  describe "album_art/1" do
    test "returns nil for a track we can't get art out of" do
      assert Commands.album_art(%{}) == nil
      assert Commands.album_art(nil) == nil
      assert Commands.album_art(%{"album" => %{"images" => []}}) == nil
      assert Commands.album_art(%{"album" => %{}}) == nil
    end

    test "returns the first image's url" do
      track = %{"album" => %{"images" => [%{"url" => "big.jpg"}, %{"url" => "small.jpg"}]}}
      assert Commands.album_art(track) == "big.jpg"
    end
  end

  describe "\\skip" do
    test "tells a user we've never seen to try again later" do
      params = %{"userId" => "no-such-user-#{System.unique_integer([:positive])}"}

      assert {:ok, _state} = handle("\\skip", params, %State{djs: []})
      assert_received {:chat, message}
      assert message =~ "I don't know you yet"
      refute_received {:send_message, _}
    end

    test "moves a waiting DJ up to second, behind whoever is at the decks" do
      user = user_fixture()

      assert {:ok, _state} =
               handle("\\skip", %{"userId" => user.rvrb_id}, %State{
                 djs: ["dj-a", "dj-b", user.rvrb_id]
               })

      assert_received {:send_message, %{method: "updateDjs", params: %{djs: djs}}}
      assert djs == ["dj-a", user.rvrb_id, "dj-b"]
      assert_received {:chat, "You're next up!"}
      assert Rvrb.User.get(user.rvrb_id).received_skip == true
    end

    # The DJ at the head of the queue is the one currently playing.
    # Reordering used to lift them out and put them back at position 2,
    # handing their slot to the next DJ and spending their one skip - and
    # `updateChannelDjs` tells new DJs to use \skip when they're ready.
    test "leaves the DJ at the decks where they are, and keeps their skip" do
      user = user_fixture()

      assert {:ok, _state} =
               handle("\\skip", %{"userId" => user.rvrb_id}, %State{
                 djs: [user.rvrb_id, "dj-b", "dj-c"]
               })

      refute_received {:send_message, _}
      assert_received {:chat, "Skipping wont do anything right now."}
      assert Rvrb.User.get(user.rvrb_id).received_skip != true
    end

    test "is a no-op for the only DJ in the room" do
      user = user_fixture()

      assert {:ok, _state} =
               handle("\\skip", %{"userId" => user.rvrb_id}, %State{djs: [user.rvrb_id]})

      refute_received {:send_message, _}
      assert_received {:chat, "Skipping wont do anything right now."}
      assert Rvrb.User.get(user.rvrb_id).received_skip != true
    end

    test "is a no-op for a DJ already second in line" do
      user = user_fixture()

      assert {:ok, _state} =
               handle("\\skip", %{"userId" => user.rvrb_id}, %State{
                 djs: ["dj-a", user.rvrb_id, "dj-c"]
               })

      refute_received {:send_message, _}
      assert_received {:chat, "Skipping wont do anything right now."}
      assert Rvrb.User.get(user.rvrb_id).received_skip != true
    end

    test "turns away a DJ who has already had their skip" do
      user = user_fixture()
      Rvrb.User.update_received_skip(user)

      assert {:ok, _state} =
               handle("\\skip", %{"userId" => user.rvrb_id}, %State{
                 djs: ["dj-a", "dj-b", user.rvrb_id]
               })

      refute_received {:send_message, _}
      assert_received {:chat, message}
      assert message =~ "already received a skip"
    end

    test "turns away someone who isn't DJing" do
      user = user_fixture()

      assert {:ok, _state} =
               handle("\\skip", %{"userId" => user.rvrb_id}, %State{djs: ["dj-a", "dj-b"]})

      refute_received {:send_message, _}
      assert_received {:chat, message}
      assert message =~ "have to be DJing"
      assert Rvrb.User.get(user.rvrb_id).received_skip != true
    end
  end

  describe "dispatch" do
    test "a raising handler degrades to a chat message, not a crash" do
      # \djs reads state.djs, so a bare map (rather than a `%State{}`)
      # raises a KeyError deep inside the handler - stand-in for any
      # future handler bug.
      assert {:ok, _state} = handle("\\djs", %{}, %{})
      assert_received {:chat, message}
      assert message =~ "Something went wrong running \\djs"
    end

    test "still reports unknown commands" do
      assert {:ok, _state} = handle("\\nope", %{}, %{})
      assert_received {:chat, message}
      assert message =~ "Unknown command \\nope"
    end

    test "leaves non-commands alone" do
      assert Commands.handle("just chatting", %{}, %{}) == :not_a_command
    end
  end

  # Handlers log as they go; swallow that so the suite stays readable, and
  # hand back what the handler returned.
  defp handle(payload, params, state) do
    capture_log(fn -> send(self(), {:handled, Commands.handle(payload, params, state)}) end)

    assert_received {:handled, result}
    result
  end
end
