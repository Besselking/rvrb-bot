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

  defmodule SocketStub do
    @behaviour Rvrb.Socket

    @impl true
    def chat(message), do: send(self(), {:chat, message})

    @impl true
    def send_message(message), do: send(self(), {:send_message, message})

    @impl true
    def send_queue(queue), do: send(self(), {:send_queue, queue})

    @impl true
    def edit_user(user_id, params), do: send(self(), {:edit_user, user_id, params})

    @impl true
    def update_djs(channel_id, djs), do: send(self(), {:update_djs, channel_id, djs})

    @impl true
    def refresh_admins(channel_id), do: send(self(), {:refresh_admins, channel_id})
  end

  setup do
    # The auto-vote talks to the socket through `Rvrb.Socket`, so here it
    # talks to a stub that forwards to the test process instead of a live
    # websocket.
    previous = Application.get_env(:rvrb, :socket)
    Application.put_env(:rvrb, :socket, SocketStub)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:rvrb, :socket)
        module -> Application.put_env(:rvrb, :socket, module)
      end
    end)
  end

  describe "smallest_image_url/1" do
    test "picks the smallest of the album's images" do
      album = %{
        "images" => [
          %{"width" => 640, "url" => "big.jpg"},
          %{"width" => 64, "url" => "tiny.jpg"},
          %{"width" => 300, "url" => "medium.jpg"}
        ]
      }

      assert WebSocket.smallest_image_url(album) == "tiny.jpg"
    end

    # `Enum.min_by/2` raises `Enum.EmptyError` here, which `Commands.run/5`
    # would contain - but `\\queue` would fail for the whole room over one
    # album with no cover art.
    test "returns nil rather than raising for an album with no images" do
      assert WebSocket.smallest_image_url(%{"images" => []}) == nil
      assert WebSocket.smallest_image_url(%{}) == nil
      assert WebSocket.smallest_image_url(%{"images" => nil}) == nil
      assert WebSocket.smallest_image_url(nil) == nil
    end
  end

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

      refute_received {:send_message, _}
    end

    # One queued DJ agreeing with themselves isn't the room's opinion.
    test "doesn't auto-vote on a single queued DJ's vote" do
      state = %State{djs: ["dj-a", "dj-b"]}

      assert {:ok, %{doped: false, starred: false}} =
               handle(meter(%{"dj-b" => %{"dope" => 1, "star" => 1}}), state)

      refute_received {:send_message, _}
    end

    test "auto-dopes and stars once two queued DJs agree" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c"]}

      assert {:ok, %{doped: true, starred: true, dopes: dopes}} =
               handle(
                 meter(%{
                   "dj-b" => %{"dope" => 1, "star" => 1},
                   "dj-c" => %{"dope" => 1, "star" => 1}
                 }),
                 state
               )

      assert Enum.sort(dopes) == ["dj-b", "dj-c"]
      assert_received {:send_message, %{method: "vote", params: %{dope: true}}}
      assert_received {:send_message, %{method: "vote", params: %{star: true}}}
    end

    test "only dopes for a queue that agrees on the dope alone" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c"]}

      assert {:ok, %{doped: true, starred: false}} =
               handle(
                 meter(%{
                   "dj-b" => %{"dope" => 1, "star" => 1},
                   "dj-c" => %{"dope" => 1, "star" => 0}
                 }),
                 state
               )

      assert_received {:send_message, %{method: "vote", params: %{dope: true}}}
      refute_received {:send_message, %{method: "vote", params: %{star: true}}}
    end

    test "takes the dope back when a queued DJ withdraws theirs" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c"], doped: true, dopes: ["dj-b", "dj-c"]}

      assert {:ok, %{doped: false}} =
               handle(meter(%{"dj-b" => %{"dope" => 1, "star" => 0}}), state)

      assert_received {:send_message, %{method: "vote", params: %{dope: false}}}
    end

    test "leaves a bot in the queue out of the count" do
      state = %State{djs: ["dj-a", "bot-self", "dj-b"], bots: MapSet.new(["bot-self"])}

      assert {:ok, %{doped: false}} =
               handle(meter(%{"dj-b" => %{"dope" => 1, "star" => 0}}), state)

      # Only one DJ's vote actually counts here, so the bot holds - but it
      # holds because of the floor, not because it is waiting on itself.
      refute_received {:send_message, _}
    end
  end

  describe "updateChannelUsers" do
    test "remembers which users RVRB marks as bots" do
      users = [
        %{"_id" => "user-1", "userName" => "u1", "createdDate" => "2024-01-01T00:00:00.000Z"},
        %{
          "_id" => "bot-1",
          "userName" => "bot_1",
          "type" => "bot",
          "createdDate" => "2024-01-01T00:00:00.000Z"
        }
      ]

      assert {:ok, state} =
               handle(
                 %{"method" => "updateChannelUsers", "params" => %{"users" => users}},
                 %State{}
               )

      assert state.bots == MapSet.new(["bot-1"])
    end

    test "finds the bot's own id by its user name, and keeps it" do
      users = [
        %{"_id" => "user-1", "userName" => "u1", "createdDate" => "2024-01-01T00:00:00.000Z"},
        %{"_id" => "bot-1", "userName" => "dj_bot", "createdDate" => "2024-01-01T00:00:00.000Z"}
      ]

      assert {:ok, state} =
               handle(
                 %{"method" => "updateChannelUsers", "params" => %{"users" => users}},
                 %State{bot_user_name: "dj_bot"}
               )

      assert state.bot_id == "bot-1"

      assert {:ok, state} =
               handle(
                 %{"method" => "updateChannelUsers", "params" => %{"users" => []}},
                 state
               )

      assert state.bot_id == "bot-1"
    end

    # The database write is wrapped, but `AutoVote.bot_ids/1` ran after it
    # and outside that wrapper - so a `users` payload it couldn't read
    # raised its way out of `handle_message/2` and dropped the connection,
    # taking the track queue, the DJ list and the current track with it.
    for {label, users} <- [
          {"a list of strings", ["not-a-user"]},
          {"a list of nils", [nil]},
          {"a map instead of a list", %{"a" => 1}},
          {"a bare string", "nope"},
          {"a list of lists", [[1, 2]]}
        ] do
      test "survives a users payload that is #{label}" do
        assert {:ok, %State{} = state} =
                 handle(
                   %{
                     "method" => "updateChannelUsers",
                     "params" => %{"users" => unquote(Macro.escape(users))}
                   },
                   %State{}
                 )

        assert state.bots == MapSet.new()
      end
    end

    test "keeps the readable users when the same push carries junk" do
      users = [
        "junk",
        %{
          "_id" => "bot-1",
          "userName" => "b",
          "type" => "bot",
          "createdDate" => "2024-01-01T00:00:00.000Z"
        },
        %{"_id" => "user-1", "userName" => "u", "createdDate" => "2024-01-01T00:00:00.000Z"}
      ]

      assert {:ok, state} =
               handle(
                 %{"method" => "updateChannelUsers", "params" => %{"users" => users}},
                 %State{}
               )

      assert state.bots == MapSet.new(["bot-1"])
    end

    # Everything in the handler reads `params` by key, starting with the
    # log line, so a push whose params isn't an object has to fall through
    # rather than raise.
    test "falls through to the catch-all when params isn't a map" do
      for params <- ["a string", 42, nil, [1, 2]] do
        assert {:ok, %State{}} =
                 handle(%{"method" => "updateChannelUsers", "params" => params}, %State{})
      end
    end
  end

  describe "updateChannelDjs" do
    setup do
      for id <- ~w[dj-a dj-b dj-c dj-d bot-self] do
        user_fixture(%{
          rvrb_id: id,
          last_djed: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        })
      end

      :ok
    end

    test "auto-dopes when the DJ who hadn't voted leaves the queue" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c", "dj-d"], dopes: ["dj-b", "dj-c"]}

      assert {:ok, %{doped: true}} = handle(djs(["dj-a", "dj-b", "dj-c"]), state)

      assert_received {:send_message, %{method: "vote", params: %{dope: true}}}
    end

    test "takes the vote back when a DJ who hasn't voted joins" do
      state = %State{
        djs: ["dj-a", "dj-b", "dj-c"],
        dopes: ["dj-b", "dj-c"],
        stars: ["dj-b", "dj-c"],
        doped: true,
        starred: true
      }

      assert {:ok, %{doped: false, starred: false}} =
               handle(djs(["dj-a", "dj-b", "dj-c", "dj-d"]), state)

      assert_received {:send_message, %{method: "vote", params: %{dope: false}}}
      assert_received {:send_message, %{method: "vote", params: %{star: false}}}
    end

    test "keeps the vote when the queue shrinks to one agreeing DJ" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c"], dopes: ["dj-b", "dj-c"], doped: true}

      assert {:ok, %{doped: true}} = handle(djs(["dj-a", "dj-b"]), state)

      refute_received {:send_message, %{method: "vote"}}
    end

    test "keeps the vote when the queue empties out behind the current DJ" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c"], dopes: ["dj-b", "dj-c"], doped: true}

      assert {:ok, %{doped: true}} = handle(djs(["dj-a"]), state)

      refute_received {:send_message, %{method: "vote"}}
    end

    test "doesn't start a vote for the single DJ a leaver left behind" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c"], dopes: ["dj-b"]}

      assert {:ok, %{doped: false}} = handle(djs(["dj-a", "dj-b"]), state)

      refute_received {:send_message, _}
    end

    test "doesn't wait on a bot in the queue to make it unanimous" do
      state = %State{
        djs: ["dj-a", "dj-b", "dj-c"],
        bots: MapSet.new(["bot-self"]),
        dopes: ["dj-b", "dj-c"]
      }

      assert {:ok, %{doped: true}} = handle(djs(["dj-a", "dj-b", "bot-self", "dj-c"]), state)

      assert_received {:send_message, %{method: "vote", params: %{dope: true}}}
    end

    test "puts a DJ who drops out and returns back in their spot" do
      {:ok, state} =
        handle(
          djs(["dj-a", "dj-b", "dj-c", "dj-d"]),
          %State{channel_id: "chan-1", djs: ["dj-a", "dj-b", "dj-c", "dj-d"]}
          |> Map.put(:djs, ["dj-a", "dj-b", "dj-c", "dj-d"])
        )

      assert state.dropped == %{}

      {:ok, state} = handle(djs(["dj-a", "dj-b", "dj-d"]), state)
      assert %{"dj-c" => %{position: 2}} = state.dropped
      refute_received {:update_djs, _, _}

      {:ok, state} = handle(djs(["dj-a", "dj-b", "dj-d", "dj-c"]), state)
      assert_received {:update_djs, "chan-1", ["dj-a", "dj-b", "dj-c", "dj-d"]}
      assert_received {:chat, message}
      assert message =~ "Welcome back"
      assert message =~ "spot 3 of the queue."
      assert state.dropped == %{}
      assert state.djs == ["dj-a", "dj-b", "dj-d", "dj-c"]
    end

    test "moves them up for the tracks played while they were away" do
      state = %State{channel_id: "chan-1", djs: ["dj-a", "dj-b", "dj-c", "dj-d"]}
      {:ok, state} = handle(djs(["dj-a", "dj-b", "dj-d"]), state)

      # One track started while they were away.
      state = %{state | plays: 1}

      {:ok, _state} = handle(djs(["dj-b", "dj-d", "dj-a", "dj-c"]), state)
      assert_received {:update_djs, "chan-1", ["dj-b", "dj-c", "dj-d", "dj-a"]}
    end

    test "says nothing when the returning DJ stays at the back" do
      state = %State{channel_id: "chan-1", djs: ["dj-a", "dj-b"]}
      {:ok, state} = handle(djs(["dj-a"]), state)
      {:ok, _state} = handle(djs(["dj-a", "dj-b"]), state)

      refute_received {:update_djs, _, _}
      refute_received {:chat, _}
    end

    test "tells a DJ who goes next up that they are up next" do
      state = %State{channel_id: "chan-1", djs: ["dj-a", "dj-b", "dj-c"], plays: 0}
      {:ok, state} = handle(djs(["dj-a", "dj-b"]), state)
      {:ok, _state} = handle(djs(["dj-a", "dj-b", "dj-c"]), %{state | plays: 1})

      assert_received {:update_djs, "chan-1", ["dj-a", "dj-c", "dj-b"]}
      assert_received {:chat, message}
      assert message =~ "spot 2 of the queue - you're up next!"
    end

    test "does not keep a spot for the bot" do
      state = %State{channel_id: "chan-1", djs: ["dj-a", "bot-self", "dj-b"], bot_id: "bot-self"}
      {:ok, state} = handle(djs(["dj-a", "dj-b"]), state)

      assert state.dropped == %{}
    end

    # The votes we hold belong to the track that just ended, so a rotation
    # must not turn them into a vote on the next one.
    test "drops the votes it was holding when the decks rotate" do
      state = %State{djs: ["dj-a", "dj-b", "dj-c"], dopes: ["dj-b", "dj-c"]}

      assert {:ok, %{doped: false, dopes: [], stars: []}} =
               handle(djs(["dj-b", "dj-c", "dj-a"]), state)

      refute_received {:send_message, _}
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

    test "asks for the channel's admins" do
      assert {:reply, _frame, _state} =
               handle(%{"method" => "ready", "params" => %{"channelId" => "chan-1"}}, %State{})

      assert_received {:refresh_admins, "chan-1"}
    end

    test "remembers the bot's own user name" do
      assert {:reply, _frame, state} =
               handle(
                 %{
                   "method" => "ready",
                   "params" => %{"channelId" => "c", "userName" => "dj_bot"}
                 },
                 %State{}
               )

      assert state.bot_user_name == "dj_bot"
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
      assert new_state.plays == 1
      assert is_integer(new_state.current_track_started_at)
    end
  end

  describe "leaveChannel" do
    test "forgets the room but keeps the queued tracks" do
      state = %State{
        djs: ["dj-a"],
        current_track: %{"name" => "Alpha"},
        current_track_started_at: 1,
        dopes: ["dj-a"],
        stars: ["dj-a"],
        doped: true,
        starred: true,
        queue: [%{"name" => "Queued"}]
      }

      assert {:ok, new_state} =
               handle(%{"method" => "leaveChannel", "params" => %{"channelId" => "c"}}, state)

      assert new_state.djs == []
      assert new_state.current_track == %{}
      assert new_state.current_track_started_at == nil
      assert new_state.dopes == [] and new_state.stars == []
      refute new_state.doped
      refute new_state.starred
      assert new_state.queue == [%{"name" => "Queued"}]
      refute_received {:send_message, _}
    end

    test "survives a push with no params" do
      assert {:ok, %State{}} = handle(%{"method" => "leaveChannel"}, %State{})
    end
  end

  describe "channel admins" do
    test "State.admins_from_channel/1 takes admins and creators, not mods" do
      channel = %{"roles" => %{"mods" => ["m"], "admins" => ["a"], "creators" => ["c"]}}

      assert State.admins_from_channel(channel) == MapSet.new(["a", "c"])
    end

    test "State.admins_from_channel/1 tolerates missing or odd roles" do
      assert State.admins_from_channel(%{"roles" => %{}}) == MapSet.new()

      assert State.admins_from_channel(%{"roles" => %{"admins" => [1, nil, "a"]}}) ==
               MapSet.new(["a"])

      assert State.admins_from_channel(%{"roles" => nil}) == nil
      assert State.admins_from_channel(%{}) == nil
      assert State.admins_from_channel(nil) == nil
    end

    test "updateChannel replaces the admins" do
      state = %State{admins: MapSet.new(["old"])}

      message = %{
        "method" => "updateChannel",
        "params" => %{"channel" => %{"roles" => %{"admins" => ["new"]}}}
      }

      assert {:ok, %{admins: admins}} = handle(message, state)
      assert admins == MapSet.new(["new"])
    end

    test "updateChannel without roles keeps the admins" do
      state = %State{admins: MapSet.new(["old"])}
      message = %{"method" => "updateChannel", "params" => %{"channel" => %{"title" => "t"}}}

      assert {:ok, ^state} = handle(message, state)
    end

    test "the fetched admins land in the state" do
      assert {:ok, %{admins: admins}} =
               WebSocket.handle_info({:channel_admins, MapSet.new(["a"])}, %State{})

      assert admins == MapSet.new(["a"])
    end
  end

  describe "closed" do
    test "reason 1 marks the connection as replaced" do
      assert {:ok, %State{replaced: true}} =
               handle(%{"method" => "closed", "params" => %{"reason" => 1}}, %State{})
    end

    test "any other reason leaves the connection reconnectable" do
      for message <- [
            %{"method" => "closed", "params" => %{"reason" => -1}},
            %{"method" => "closed", "params" => %{}},
            %{"method" => "closed", "params" => "junk"},
            %{"method" => "closed"}
          ] do
        assert {:ok, %State{replaced: false}} = handle(message, %State{})
      end
    end
  end

  describe "reconnecting" do
    test "reconnects after a protocol error normally" do
      capture_log(fn ->
        assert WebSocket.handle_disconnect(1002, "", %State{}) == :reconnect
        assert WebSocket.handle_error(:boom, %State{}) == :reconnect
      end)
    end

    test "does not reconnect once another client replaced the connection" do
      capture_log(fn ->
        assert WebSocket.handle_disconnect(1002, "", %State{replaced: true}) == :close
        assert WebSocket.handle_error(:boom, %State{replaced: true}) == :close
      end)
    end
  end

  describe "State.snapshot/1" do
    test "projects the room without the raw track payload" do
      track = %{
        "id" => "spotify-1",
        "name" => "Windowlicker",
        "artists" => [%{"name" => "Aphex Twin", "id" => "artist-1"}],
        "duration_ms" => 360_000,
        "album" => %{"images" => [%{"url" => "http://art", "width" => 640}]}
      }

      state = %State{
        channel_id: "room-1",
        djs: ["dj-a", "dj-b"],
        current_track: track,
        current_track_started_at: System.monotonic_time(:millisecond),
        dopes: ["listener-1"],
        stars: [],
        doped: true,
        queue: [%{"name" => "Queued"}],
        bots: MapSet.new(["bot-1"])
      }

      snapshot = State.snapshot(state)

      assert snapshot.channel_id == "room-1"
      assert snapshot.djs == ["dj-a", "dj-b"]
      assert snapshot.dopes == ["listener-1"]
      assert snapshot.auto_doped
      refute snapshot.auto_starred
      assert snapshot.queued_tracks == 1
      assert snapshot.known_bots == 1

      assert snapshot.current_track == %{
               spotify_track_id: "spotify-1",
               name: "Windowlicker",
               artist_names: ["Aphex Twin"],
               spotify_artist_ids: ["artist-1"],
               duration_ms: 360_000,
               album_art: "http://art"
             }
    end

    test "reports no track before the first one has played" do
      assert State.snapshot(%State{}).current_track == nil
    end

    test "times the current track from when it started" do
      state = %State{
        current_track: %{"duration_ms" => 300_000},
        current_track_started_at: System.monotonic_time(:millisecond) - 60_000
      }

      snapshot = State.snapshot(state)

      assert_in_delta snapshot.elapsed_ms, 60_000, 1_000
      assert_in_delta snapshot.remaining_ms, 240_000, 1_000
    end

    test "leaves the timings unknown when the bot came up mid-track" do
      state = %State{current_track: %{"duration_ms" => 300_000}, current_track_started_at: nil}

      assert %{elapsed_ms: nil, remaining_ms: nil} = State.snapshot(state)
    end

    test "leaves the remaining time unknown when the track carried no duration" do
      state = %State{
        current_track: %{"name" => "Untimed"},
        current_track_started_at: System.monotonic_time(:millisecond)
      }

      assert State.snapshot(state).remaining_ms == nil
    end

    # A track that has overrun its own length reads as finished rather
    # than as negative time, which a reader would have to special-case.
    test "clamps a track that has run past its length to zero" do
      state = %State{
        current_track: %{"duration_ms" => 1_000},
        current_track_started_at: System.monotonic_time(:millisecond) - 60_000
      }

      assert State.snapshot(state).remaining_ms == 0
    end
  end

  describe "live_state/1" do
    test "answers with a snapshot of the connection's state" do
      state = %State{channel_id: "room-1", djs: ["dj-a"]}

      assert {:ok, ^state} =
               WebSocket.handle_info({:live_state, self(), :test_ref}, state)

      assert_received {:live_state, :test_ref, snapshot}
      assert snapshot.channel_id == "room-1"
      assert snapshot.djs == ["dj-a"]
    end

    test "answers nil when there is no connection to ask" do
      # Nothing is registered as `Connection` in the suite - the state a
      # status page sees whenever the bot is down.
      refute Process.whereis(Connection)
      assert WebSocket.live_state(50) == nil
    end
  end

  defp meter(voting) do
    %{"method" => "updateChannelMeter", "params" => %{"voting" => voting}}
  end

  defp djs(djs) do
    %{"method" => "updateChannelDjs", "params" => %{"type" => "update", "djs" => djs}}
  end

  defp handle(message, state) do
    capture_log(fn -> send(self(), {:handled, WebSocket.handle_message(message, state)}) end)

    assert_received {:handled, result}
    result
  end
end
