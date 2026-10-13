defmodule Rvrb.WebSocket do
  alias Rvrb.Api
  alias Rvrb.AutoVote
  alias Rvrb.Commands
  alias Rvrb.DjRestore
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
  Updates the bot's own profile. `params` holds the subset of RVRB's user
  keys to change - `displayName`, `image`, `djImage`, `thumbsUpImage`,
  `thumbsDownImage`, `bio` - and anything left out keeps its current value.

  RVRB no longer takes this over the websocket, so it is an HTTP call to
  `PATCH /api/users/{userId}`, made in a task: the connection process must
  keep answering `keepAwake` while it is in flight. A failure is said in
  chat, since the command that asked has already moved on.
  """
  def edit_user(user_id, params) do
    in_background("profile update", fn -> Api.patch_user(user_id, params) end)
  end

  @doc """
  Puts the DJ queue in the order of `djs`, over `PUT /api/channel/{id}/djs`.
  Run in a task for the same reason as `edit_user/2`.
  """
  def update_djs(channel_id, djs) do
    in_background("DJ queue update", fn -> Api.put_djs(channel_id, djs) end)
  end

  @doc """
  Reads the channel's roles and hands the connection the admins, retrying a
  few times: until it lands nobody can run an admin command. Runs in a task
  and answers with `{:channel_admins, admins}` to the connection process.
  """
  def refresh_admins(channel_id) do
    connection = Process.whereis(Connection)

    Task.start(fn -> fetch_admins(connection, channel_id, 3) end)
  end

  defp fetch_admins(connection, channel_id, attempts_left) do
    with {:ok, channel} <- Api.get_channel(channel_id),
         %MapSet{} = admins <- State.admins_from_channel(channel) do
      send(connection, {:channel_admins, admins})
    else
      _failed when attempts_left > 1 ->
        Process.sleep(:timer.seconds(5))
        fetch_admins(connection, channel_id, attempts_left - 1)

      _failed ->
        Logger.error("could not read the admins of channel #{inspect(channel_id)}")
    end
  end

  defp in_background(what, fun) do
    Task.start(fn ->
      case fun.() do
        :ok -> :ok
        {:error, message} -> chat("The #{what} failed: #{message}")
      end
    end)
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

        %{
          image: image_cell(smallest_image_url(track.album)),
          name: track.name,
          artist: artists
        }
      end

    table = Html.table(rows, [{:image, ""}, {:name, "Name"}, {:artist, "Artist"}])

    chat("current queue:" <> table)
  end

  @doc """
  The url of the smallest cover image on `album`, or nil when there isn't
  one to show.

  `Enum.min_by/2` raises `Enum.EmptyError` on `[]`, and an album with no
  images is rare but real - a missing thumbnail shouldn't cost the whole
  `\\queue` table. Public for the same reason as `Commands.album_art/1`:
  it's the part worth testing without a socket.
  """
  def smallest_image_url(%{"images" => [_ | _] = images}) do
    images |> Enum.min_by(& &1["width"]) |> Map.get("url")
  end

  def smallest_image_url(_no_images), do: nil

  defp image_cell(nil), do: ""
  defp image_cell(url), do: {:safe, "<img src=\"#{Html.escape(url)}\"/>"}

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

  def handle_disconnect(_code, _reason, %State{replaced: true}) do
    Logger.warning("Closing, another client replaced this connection")
    :close
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

  def handle_error(error, %State{replaced: true}) do
    Logger.warning("Closing after #{inspect(error)}, another client replaced this connection")
    :close
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

    state = %{state | channel_id: params["channelId"], bot_user_name: params["userName"]}

    join_message =
      JSON.encode!(%{
        method: "join",
        params: %{
          channelId: params["channelId"]
        },
        id: Enum.random(1..100)
      })

    Rvrb.Socket.impl().refresh_admins(state.channel_id)

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

  # `is_map/1` because everything below reads `params` by key: a push whose
  # `params` isn't an object at all falls through to the catch-all clause
  # instead of raising its way out of the connection process.
  def handle_message(%{"method" => "updateChannelUsers", "params" => params}, state)
      when is_map(params) do
    Logger.debug("updateChannelUsers! #{params["type"]}")

    users = params["users"] || []

    store_users(users)

    # Accumulated rather than replaced: a push carries whoever it carries,
    # and a bot doesn't stop being one by not being mentioned again.
    {:ok,
     %{
       state
       | bots: MapSet.union(state.bots, AutoVote.bot_ids(users)),
         bot_id: find_bot_id(users, state)
     }}
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
         plays: state.plays + 1,
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

    {dropped, restored} =
      DjRestore.update(
        state.dropped,
        current_djs,
        djs,
        state.plays,
        System.monotonic_time(:millisecond),
        ignored_ids(state)
      )

    # Someone who dropped out and is back inside the window goes back to
    # their spot. RVRB answers with an `updateChannelDjs` of the new order,
    # which changes nobody's membership, so it does not come round again.
    if restored != djs do
      Logger.info("restoring a returning DJ: #{inspect(djs)} => #{inspect(restored)}")
      Rvrb.Socket.impl().update_djs(state.channel_id, restored)
      announce_restored(DjRestore.moves(current_djs, djs, restored))
    end

    state = %{state | djs: djs, dropped: dropped}

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

  # Roles changed, or the channel was edited: the push carries the channel,
  # roles included. One without roles leaves the admins as they were.
  def handle_message(%{"method" => "updateChannel", "params" => %{"channel" => channel}}, state) do
    case State.admins_from_channel(channel) do
      nil -> {:ok, state}
      admins -> {:ok, %{state | admins: admins}}
    end
  end

  # The bot is no longer in the channel: kicked, banned, or the channel was
  # deleted. Rejoining on our own would undo a moderator's decision (or fail
  # for a ban or a deleted channel), so the bot stays connected but idle, and
  # drops what it knew about the room - none of it is current any more. The
  # `\queue` is kept; an admin put it there and it is still wanted.
  def handle_message(%{"method" => "leaveChannel"} = message, state) do
    channel_id = get_in_map(message, "params", "channelId")

    Logger.warning("leaveChannel! removed from channel #{inspect(channel_id)}")

    {:ok,
     %{
       state
       | djs: [],
         doped: false,
         starred: false,
         dopes: [],
         stars: [],
         current_track: %{},
         current_track_started_at: nil
     }}
  end

  # RVRB is about to close this connection. Reason 1 means another client of
  # the bot's account connected; anything else is just a close. Either way
  # the socket closing is what ends the connection, so this only records
  # why, for the disconnect and error callbacks.
  def handle_message(%{"method" => "closed"} = message, state) do
    reason = get_in_map(message, "params", "reason")

    if reason == 1 do
      Logger.warning("closed! replaced by another client, will not reconnect")
      {:ok, %{state | replaced: true}}
    else
      Logger.warning("closed! reason #{inspect(reason)}")
      {:ok, state}
    end
  end

  def handle_message(unknown_message, state) do
    Logger.debug("Received state: #{inspect(unknown_message)}")
    {:ok, state}
  end

  # The bot's own id, once a push names it. Kept when a push doesn't mention
  # the bot, and tolerant of the junk `updateChannelUsers` tests feed it.
  defp find_bot_id(users, %{bot_user_name: name, bot_id: current}) when is_list(users) do
    Enum.find_value(users, current, fn
      %{"userName" => ^name, "_id" => id} when is_binary(name) and is_binary(id) -> id
      _other -> nil
    end)
  end

  defp find_bot_id(_users, %{bot_id: current}), do: current

  # Tells the room who was put back where. `spot` counts from the front of
  # the queue, where 0 is the track playing, so the DJ's place in line is
  # one more. Names come from the users table, which the room's pushes keep
  # up to date.
  defp announce_restored([]), do: :ok

  defp announce_restored(moves) do
    users = Rvrb.User.get_users(Enum.map(moves, &elem(&1, 0)))

    for {id, spot} <- moves do
      name = Html.escape(Rvrb.User.get_name(users, id) || "DJ")
      next_up = if spot == 1, do: " - you're up next!", else: "."

      Rvrb.Socket.impl().chat(
        "Welcome back #{name}, I've put you back in spot #{spot + 1} of the queue#{next_up}"
      )
    end
  end

  # The bots' ids: their place in the queue is not worth keeping.
  defp ignored_ids(%{bot_id: nil, bots: bots}), do: bots
  defp ignored_ids(%{bot_id: bot_id, bots: bots}), do: MapSet.put(bots, bot_id)

  # `message[outer][inner]`, or nil when `outer` isn't an object.
  defp get_in_map(message, outer, inner) do
    case message[outer] do
      %{} = map -> map[inner]
      _not_a_map -> nil
    end
  end

  # The write happens here on the connection process, outside the
  # `Commands.run/5` net. Losing a push's user records costs us their stats
  # and display names; letting the failure through would cost the connection
  # and everything it holds - the track queue, the DJ list, the current
  # track. Exits too: `Rvrb.Repo` calls into a pool that can be down.
  defp store_users(users) do
    Rvrb.User.update_users(users)
  rescue
    error ->
      Logger.error(
        "updateChannelUsers write failed:\n#{Exception.format(:error, error, __STACKTRACE__)}"
      )

      []
  catch
    kind, reason ->
      Logger.error(
        "updateChannelUsers write failed:\n#{Exception.format(kind, reason, __STACKTRACE__)}"
      )

      []
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
  def handle_info({:channel_admins, admins}, state) do
    Logger.info("channel admins: #{MapSet.size(admins)}")
    {:ok, %{state | admins: admins}}
  end

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
