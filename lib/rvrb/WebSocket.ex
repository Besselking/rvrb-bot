alias Rvrb.GenreServer, as: GenreServer

defmodule Rvrb.WebSocket do
  use Fresh

  """
    edit_user_image = %{
      jsonrpc: "2.0",
      method: "editUser",
      params: %{
        displayName: "<new name>",
        image: "<image url>",
        bio: "This is a bot"
      },
      id: 1234
    }
  """

  def send_message(message) do
    data = Jason.encode!(message)
    IO.puts("OUT: #{data}")
    Fresh.send(Connection, {:text, data})
  end

  def dope() do
    send_message(%{
        jsonrpc: "2.0",
        method: "vote",
        params: %{
          dope: true
        }
      })
  end

  def star() do
    send_message(%{
        jsonrpc: "2.0",
        method: "vote",
        params: %{
          star: true
        }
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

  def start_link(bot_key) when is_binary(bot_key) do
    Fresh.start_link(
      "wss://app.rvrb.one/ws-bot?apiKey=#{bot_key}",
      Rvrb.WebSocket,
      %{
        autodope: false,
        djs: [],
        doped: false,
        starred: false,
        debug_djs: true
      },
      name: {:local, Connection}
    )
  end

  def handle_connect(_status, headers, state) do
    IO.puts("Upgrade request headers: #{inspect(headers)}")
    {:ok, state}
  end

  def handle_disconnect(1002, _reason, _state) do
    IO.puts("Reconnecting")
    :reconnect
  end

  def handle_disconnect(code, reason, _state) do
    IO.puts("closing, #{code} #{reason}")
    :close
  end

  def handle_error({error, reason}, state)
      when error in [:encoding_failed, :casting_failed] do
    IO.puts("ERROR: #{error} #{reason}")
    {:ignore, state}
  end

  def handle_error(error, _state) do
    IO.puts("ERROR: #{error}")
    :reconnect
  end

  def handle_pushChannelMessage(%{"payload" => "\\qg"}, state) do
    IO.puts("command qg!")

    chat(GenreServer.get_genre())

    {:ok, state}
  end

  def handle_pushChannelMessage(%{"payload" => "\\qg " <> keyword}, state) do
    IO.puts("command qg! #{keyword}")

    chat(GenreServer.get_genre(keyword))

    {:ok, state}
  end

  def handle_pushChannelMessage(%{"payload" => "\\autodope"}, state) do
    IO.puts("command autodope!")

    state = %{state | :autodope => !state[:autodope]}

    if state[:autodope] do
      chat("Autodope turned on")
      dope()
    else
      chat("Autodope turned off")
    end

    {:ok, state}
  end

  def handle_pushChannelMessage(%{"payload" => "\\djs"}, state) do
    IO.puts("command djs!")

    current_djs = state[:djs]
    dj_map = Rvrb.User.get_users(current_djs)

    djs = for dj <- current_djs do
      { Rvrb.User.get_name(dj_map, dj), Rvrb.User.get_last_djed(dj_map, dj), Rvrb.User.get_created_date(dj_map, dj)}
    end

    use Timex

    rows = for {name, last_djed, created_date} <- djs do
      relative_date = if last_djed != nil do
        Timex.from_now(last_djed)
      else
        ""
      end

      "<tr><td>#{name}</td><td>#{relative_date}</td><td>#{Timex.from_now(created_date)}</td></tr>"
    end

    table = "<table class=\"chat-table striped\">
      <thead>
        <tr><th>Name</th><th>Last DJed</th><th>Member Since</th></tr>
      </thead>
      <tbody>#{Enum.join(rows)}</tbody>
    </table>"

    chat(table)

    {:ok, state}
  end

  def handle_pushChannelMessage(%{"type" => "alert"} = params, state) do
    %{"payload" => payload, "syncTime" => synctime} = params

    IO.puts("alert! #{inspect(payload)} #{inspect(synctime)}")

    state =
      if String.ends_with?(payload, "chat messages were deleted by bot_1728728144538") do
        Map.put(state, :last_deletion, synctime)
      else
        state
      end

    {:ok, state}
  end

  def handle_pushChannelMessage(%{"payload" => "\\whisperback"} = params, state) do
    IO.puts("command whisperback!")
    %{"userId" => userId} = params

    user = Rvrb.User.get(userId)

    chat("/w @#{user.display_name} hi there!")

    {:ok, state}
  end

  def handle_pushChannelMessage(params, state) do
    IO.puts("pushChannelMessage! #{inspect(params)}")
    {:ok, state}
  end

  def handle_message(%{"method" => "pushChannelMessage", "params" => params}, state) do
    handle_pushChannelMessage(params, state)
  end

  def handle_message(%{"method" => "ready", "params" => params}, state) do
    IO.puts("ready! #{inspect(params)}")

    state = Map.put(state, :channelId, params["channelId"])

    join_message =
      Jason.encode!(%{
        method: "join",
        params: %{
          channelId: params["channelId"]
        },
        id: Enum.random(1..100)
      })

    IO.puts("OUT: #{join_message}")
    {:reply, {:text, join_message}, state}
  end

  def handle_message(%{"method" => "keepAwake", "params" => params}, state) do
    IO.puts("keepAwake! #{inspect(params)}")

    state = Map.put(state, :latency, params["latency"])

    keepAwake_message =
      Jason.encode!(%{
        method: "stayAwake",
        params: %{
          date: System.os_time(:second)
        }
      })

    IO.puts("OUT: #{keepAwake_message}")
    {:reply, {:text, keepAwake_message}, state}
  end

  def handle_message(%{"method" => "updateChannelUsers", "params" => params}, state) do
    IO.puts("updateChannelUsers! #{params["type"]}")

    Rvrb.User.update_users(params["users"])

    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelMeter", "params" => params}, state) do
    IO.puts("updateChannelMeter!")
    voting = params["voting"]
    dopes = for {userid, vote} <- voting, vote["dope"] > 0, do: userid
    stars = for {userid, vote} <- voting, vote["star"] > 0, do: userid

    [_current_dj | djs] = state[:djs]

    doped = if not Enum.empty?(djs) and Enum.empty?(djs -- dopes) and not state[:doped] do
      dope()
      true
    else
      state[:starred]
    end

    starred = if not Enum.empty?(djs) and Enum.empty?(djs -- stars) and not state[:starred] do
      star()
      true
    else
      state[:starred]
    end

    vote_user_ids = Map.keys(voting)
    voted_users = Rvrb.User.get_users(vote_user_ids)

    for {userid, votes} <- voting do
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

      IO.puts("#{name}: \t#{vote}")
    end

    {:ok, %{state | doped: doped, starred: starred}}
  end

  def handle_message(
        %{"method" => "playChannelTrack", "params" => params},
        %{autodope: true} = state
      ) do
    track = params["track"]
    IO.puts("playChannelTrack! #{inspect(track["name"])} - #{inspect(track["artist"]["name"])}")

    dope()

    {:ok, state}
  end

  def handle_message(
        %{"method" => "playChannelTrack", "params" => params},
        state
      ) do
    track = params["track"]
    IO.puts("playChannelTrack! #{inspect(track["name"])} - #{inspect(track["artist"]["name"])}")
    # IO.puts("playChannelTrack! #{inspect(track)}")

    {:ok, %{state | doped: false, starred: false}}
  end

  def handle_message(%{"method" => "updateChannelUserStatus"}, state) do
    # IO.puts("updateChannelUserStatus! #{inspect(params)}")
    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelDjs", "params" => params}, state) do
    IO.puts("updateChannelDjs! #{params["type"]}")

    current_djs = state[:djs]
    djs = params["djs"]

    case djs do
      [current_dj_id | _] ->
        current_dj = Rvrb.User.get(current_dj_id)
        Rvrb.User.update_last_djed(current_dj)
      [] -> nil
    end

    #contains duplicates
    all_djs = current_djs ++ djs
    users = Rvrb.User.get_users(all_djs)

    djs_left = current_djs -- djs
    djs_joined = djs -- current_djs

    if state[:debug_djs] do
      for dj <- djs_left do
        IO.puts("\t #{Rvrb.User.get_name(users, dj)} left")
      end
      for dj <- djs_joined do
        IO.puts("\t #{Rvrb.User.get_name(users, dj)} joined")
      end
    end

    state = %{state | djs: djs}

    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelHistory"}, state) do
    # IO.puts("updateChannelUserStatus! #{inspect(params)}")
    {:ok, state}
  end

  def handle_message(unknown_message, state) do
    IO.puts("Received state: #{inspect(unknown_message)}")
    {:ok, state}
  end

  def handle_in({:text, data}, state) do
    # IO.puts("IN: #{data}")
    message = Jason.decode!(data)

    handle_message(message, state)
  end

  def handle_terminate(reason, _state) do
    IO.puts("Process is terminating with reason: #{inspect(reason)}")
    # chat("Bot is shutting down...")
    send_message(%{
      method: "leave"
    })

    :ok
  end
end
