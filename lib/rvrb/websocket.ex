defmodule Rvrb.WebSocket do
  alias Rvrb.AutoVote
  alias Rvrb.Commands
  alias Rvrb.PlayWriter
  alias Rvrb.WebSocket.State
  use Fresh

  require Logger

  @behaviour Rvrb.Socket

  def send_message(message) do
    data = JSON.encode!(message)
    Logger.debug("OUT: #{data}")
    Fresh.send(Connection, {:text, data})
  end

  @doc """
  Updates the bot's own profile. `params` holds the subset of RVRB's
  `editUser` keys to change - `displayName`, `image`, `djImage`,
  `thumbsUpImage`, `thumbsDownImage`, `bio` - and anything left out keeps
  its current value.
  """
  def edit_user(params) do
    send_message(%{
      jsonrpc: "2.0",
      method: "editUser",
      params: params,
      id: Enum.random(1..1000)
    })
  end

  def dope(), do: cast_vote(%{dope: true})

  @doc "Takes back a dope the bot cast, leaving every other vote alone."
  def undope(), do: cast_vote(%{dope: false})

  def star(), do: cast_vote(%{star: true})

  @doc "Takes back a star the bot cast, leaving every other vote alone."
  def unstar(), do: cast_vote(%{star: false})

  # Through `Rvrb.Socket` rather than `send_message/1` directly so a test
  # can stub the socket and assert on what the auto-vote decided, the same
  # way the command handlers do.
  defp cast_vote(params) do
    Rvrb.Socket.impl().send_message(%{
      jsonrpc: "2.0",
      method: "vote",
      params: params
    })
  end

  def chat(message) do
    send_message(%{
      method: "pushMessage",
      params: %{
        payload: message
      }
    })
  end

  def send_queue(queue) do
    rows =
      for track <- queue do
        artists =
          track.artists
          |> Enum.map(fn artist -> artist["name"] end)
          |> Enum.join(", ")

        smallest_image_url =
          (track.album["images"]
           |> Enum.min_by(& &1["width"]))["url"]

        %{
          image: {:safe, "<img src=\"#{Html.escape(smallest_image_url)}\"/>"},
          name: track.name,
          artist: artists
        }
      end

    table = Html.table(rows, [{:image, ""}, {:name, "Name"}, {:artist, "Artist"}])

    chat("current queue:" <> table)
  end

  @doc """
  The connection's live view of the room - see `Rvrb.WebSocket.State.snapshot/1`
  for what's in it - or `nil` when the bot isn't connected (no socket
  process, or one too busy to answer inside `timeout`).

  A plain send/receive rather than a `GenServer.call/3`: Fresh owns the
  process and exposes `handle_info/2` but no call callback, and reading
  the room's state must never be able to make the socket wait on the
  caller. `nil` is a normal answer here, not an error - the bot being
  down is exactly what a status page is asking about.
  """
  def live_state(timeout \\ 2_000) do
    case Process.whereis(Connection) do
      nil ->
        nil

      pid ->
        ref = make_ref()
        send(pid, {:live_state, self(), ref})

        receive do
          {:live_state, ^ref, snapshot} -> snapshot
        after
          timeout -> nil
        end
    end
  end

  def start_link(bot_key) when is_binary(bot_key) do
    Fresh.start_link(
      "wss://app.rvrb.one/ws-bot?apiKey=#{bot_key}",
      Rvrb.WebSocket,
      %State{},
      name: {:local, Connection}
    )
  end

  def handle_connect(_status, headers, state) do
    Logger.info("Connected")
    Logger.debug("Upgrade request headers: #{inspect(headers)}")
    {:ok, state}
  end

  def handle_disconnect(1002, _reason, _state) do
    Logger.warning("Reconnecting")
    :reconnect
  end

  def handle_disconnect(code, reason, _state) do
    Logger.warning("Closing, #{code} #{reason}")
    :close
  end

  def handle_error({error, reason}, state)
      when error in [:encoding_failed, :casting_failed] do
    Logger.error("#{error} #{reason}")
    {:ignore, state}
  end

  def handle_error(error, _state) do
    # `inspect` rather than interpolation: most errors reaching here are
    # tuples (`{:establishing_failed, %Mint.WebSocket.UpgradeFailureError{}}`
    # and friends), and String.Chars raising here would turn a reconnectable
    # error into a crash.
    Logger.error(inspect(error))
    :reconnect
  end

  def handle_pushChannelMessage(%{"type" => "alert"} = params, state) do
    %{"payload" => payload, "syncTime" => synctime} = params

    Logger.info("alert! #{inspect(payload)} #{inspect(synctime)}")

    {:ok, state}
  end

  def handle_pushChannelMessage(%{"payload" => payload} = params, state)
      when is_binary(payload) do
    case Commands.handle(payload, params, state) do
      :not_a_command ->
        Logger.debug("pushChannelMessage! #{inspect(params)}")
        {:ok, state}

      result ->
        result
    end
  end

  def handle_pushChannelMessage(params, state) do
    Logger.debug("pushChannelMessage! #{inspect(params)}")
    {:ok, state}
  end

  def handle_message(%{"method" => "pushChannelMessage", "params" => params}, state) do
    handle_pushChannelMessage(params, state)
  end

  def handle_message(%{"method" => "ready", "params" => params}, state) do
    Logger.info("ready! #{inspect(params)}")

    state = %{state | channel_id: params["channelId"]}

    join_message =
      JSON.encode!(%{
        method: "join",
        params: %{
          channelId: params["channelId"]
        },
        id: Enum.random(1..100)
      })

    Logger.debug("OUT: #{join_message}")
    {:reply, {:text, join_message}, state}
  end

  def handle_message(%{"method" => "keepAwake", "params" => params}, state) do
    Logger.debug("keepAwake! #{inspect(params)}")

    keepAwake_message =
      JSON.encode!(%{
        method: "stayAwake",
        params: %{
          date: System.os_time(:second)
        }
      })

    Logger.debug("OUT: #{keepAwake_message}")
    {:reply, {:text, keepAwake_message}, state}
  end

  def handle_message(%{"method" => "updateChannelUsers", "params" => params}, state) do
    Logger.debug("updateChannelUsers! #{params["type"]}")

    users = params["users"] || []

    Rvrb.User.update_users(users)

    # Accumulated rather than replaced: a push carries whoever it carries,
    # and a bot doesn't stop being one by not being mentioned again.
    {:ok, %{state | bots: MapSet.union(state.bots, AutoVote.bot_ids(users))}}
  end

  # RVRB asks for a track when it's the bot's turn to DJ. With an empty
  # queue there's nothing to hand it, so answer the RPC with an error and
  # step off the decks rather than sitting there dead - an admin can
  # \queue something and \join again.
  def handle_message(%{"method" => "nextChannelTrack"} = params, %{queue: []} = state) do
    Logger.warning("nextChannelTrack! (queue empty)")

    error_response =
      JSON.encode!(%{
        error: %{code: -32000, message: "no tracks queued"},
        id: params["id"]
      })

    chat("My queue is empty, so I'm stepping off the decks - queue me something with \\queue.")
    send_message(%{method: "leaveDjs"})

    Logger.debug("OUT: #{error_response}")
    {:reply, {:text, error_response}, state}
  end

  def handle_message(%{"method" => "nextChannelTrack"} = params, state) do
    Logger.info("nextChannelTrack!")

    [next_track | queue] = state.queue

    track_response =
      JSON.encode!(%{
        result: %{
          track: next_track
        },
        id: params["id"]
      })

    Logger.debug("OUT: #{track_response}")
    {:reply, {:text, track_response}, %{state | :queue => queue}}
  end

  def handle_message(%{"method" => "updateChannelMeter", "params" => params}, state) do
    Logger.debug("updateChannelMeter!")
    voting = params["voting"]

    PlayWriter.sync_votes(voting)

    state = %{
      state
      | dopes: AutoVote.voters(voting, "dope"),
        stars: AutoVote.voters(voting, "star")
    }

    state = refresh_auto_votes(state)

    # A meter arrives for every vote anyone casts, so the per-voter dump goes
    # behind a lazy `Logger.debug/1`: with debug off, neither the user lookup
    # nor the lines themselves happen at all.
    Logger.debug(fn ->
      voted_users = Rvrb.User.get_users(Map.keys(voting))

      Enum.map_join(voting, "\n", fn {userid, votes} ->
        name = Rvrb.User.get_name(voted_users, userid)

        vote =
          for {vote, count} <- votes, count > 0 do
            case vote do
              "dope" -> "👍"
              "star" -> "🔖"
              "boofstar" -> "👎🔖"
              "nope" -> "👎"
              _ -> ""
            end
          end

        "#{name}: \t#{vote}"
      end)
    end)

    {:ok, state}
  end

  def handle_message(
        %{"method" => "playChannelTrack", "params" => params},
        state
      ) do
    track = params["track"]

    Logger.info(
      "playChannelTrack! #{inspect(track["name"])} - #{inspect(track["artist"]["name"])}"
    )

    Logger.debug("playChannelTrack! #{inspect(track)}")

    PlayWriter.record(state.djs, track)

    {:ok,
     %{
       state
       | doped: false,
         starred: false,
         dopes: [],
         stars: [],
         current_track: track,
         current_track_started_at: System.monotonic_time(:millisecond)
     }}
  end

  def handle_message(%{"method" => "updateChannelUserStatus"} = message, state) do
    Logger.debug("updateChannelUserStatus! #{inspect(message)}")
    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelDjs", "params" => params}, state) do
    Logger.info("updateChannelDjs! #{params["type"]}")

    current_djs = state.djs
    djs = params["djs"]
    djs_left = current_djs -- djs
    djs_joined = djs -- current_djs
    all_djs = current_djs ++ djs
    users = Rvrb.User.get_users(all_djs)

    fresh_djs = Enum.filter(djs_joined, &(Rvrb.User.get_last_djed(users, &1) == nil))

    case djs do
      [current_dj_id | _] ->
        current_dj = Rvrb.User.get(current_dj_id)
        Rvrb.User.update_last_djed(current_dj)

      [] ->
        nil
    end

    # contains duplicates

    for dj <- fresh_djs do
      chat(
        "Hi #{Html.escape(Rvrb.User.get_name(users, dj))}, looks like this is your first time DJing in this room.
        <br/>First-timers get a skip to the front, when you're ready use <strong>\\skip</strong> to skip to the front of the queue!"
      )
    end

    for dj <- djs_left do
      Logger.info("\t #{Rvrb.User.get_name(users, dj)} left")
    end

    for dj <- djs_joined do
      Logger.info("\t #{Rvrb.User.get_name(users, dj)} joined")
    end

    state = %{state | djs: djs}

    # A DJ leaving can complete a unanimous vote, and one joining can break
    # it, so the queue that just changed gets re-checked against the votes
    # from the last meter - but only while the same DJ is still playing.
    # A different head means the decks rotated, and the votes we're holding
    # belong to the track that just ended; `playChannelTrack` clears them
    # too, this just doesn't depend on which of the two lands first.
    state =
      if List.first(current_djs) == List.first(djs) do
        refresh_auto_votes(state)
      else
        %{state | dopes: [], stars: []}
      end

    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelHistory"} = message, state) do
    Logger.debug("updateChannelHistory! #{inspect(message)}")
    {:ok, state}
  end

  def handle_message(unknown_message, state) do
    Logger.debug("Received state: #{inspect(unknown_message)}")
    {:ok, state}
  end

  # Casts or retracts the automatic dope/star to match the room as we
  # currently know it: the votes from the last meter, against the DJs whose
  # votes count right now. Safe to call on any event that moves either.
  defp refresh_auto_votes(state) do
    djs = AutoVote.deciding_djs(state.djs, state.bots)

    doped =
      state.doped
      |> AutoVote.decide(state.dopes, djs)
      |> apply_vote("dope", state.doped, &dope/0, &undope/0)

    starred =
      state.starred
      |> AutoVote.decide(state.stars, djs)
      |> apply_vote("star", state.starred, &star/0, &unstar/0)

    %{state | doped: doped, starred: starred}
  end

  defp apply_vote(:vote, name, _voted?, cast, _retract) do
    Logger.info("auto-#{name}: the DJ queue is unanimous")
    cast.()
    true
  end

  defp apply_vote(:retract, name, _voted?, _cast, retract) do
    Logger.info("un-#{name}: the DJ queue no longer agrees")
    retract.()
    false
  end

  defp apply_vote(:hold, _name, voted?, _cast, _retract), do: voted?

  # Answers `live_state/1`. Nothing here touches the database or the
  # socket: it's a projection of state we already hold, so a reader
  # hammering it can't slow the room down or wedge the connection.
  def handle_info({:live_state, from, ref}, state) do
    send(from, {:live_state, ref, State.snapshot(state)})
    {:ok, state}
  end

  def handle_in({:text, data}, state) do
    Logger.debug("IN: #{data}")
    message = JSON.decode!(data)

    handle_message(message, state)
  end

  def handle_terminate(reason, _state) do
    Logger.warning("Process is terminating with reason: #{inspect(reason)}")
    # chat("Bot is shutting down...")
    send_message(%{
      method: "leave"
    })

    :ok
  end
end
