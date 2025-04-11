alias Rvrb.GenreServer, as: GenreServer

defmodule Rvrb.WebSocket do
  use Fresh

  def start_link(bot_key) when is_binary(bot_key) do
    Fresh.start_link(
      "wss://app.rvrb.one/ws-bot?apiKey=#{bot_key}",
      Rvrb.WebSocket,
      %{},
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

  def handle_message(%{"method" => "ready", "params" => params}, state) do
    IO.puts("ready! #{inspect(params)}")

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

  def handle_message(
        %{
          "method" => "pushChannelMessage",
          "params" => %{"payload" => "\\qg", "syncTime" => synctime}
        },
        state
      ) do
    IO.puts("command qg!")

    pushMessage_message =
      Jason.encode!(%{
        method: "pushMessage",
        params: %{
          payload: GenreServer.get_genre(),
          replyTo: synctime
        }
      })

    IO.puts("OUT: #{pushMessage_message}")

    {:reply, {:text, pushMessage_message}, state}
  end

  def handle_message(%{"method" => "pushChannelMessage", "params" => params}, state) do
    # IO.puts("pushChannelMessage! #{inspect(params)}")
    IO.puts("pushChannelMessage! #{inspect(params["userName"])}: #{inspect(params["payload"])}")
    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelUsers", "params" => params}, state) do
    IO.puts("updateChannelUsers! #{length(params["users"])}")
    {:ok, state}
  end

  def handle_message(%{"method" => "playChannelTrack", "params" => params}, state) do
    track = params["track"]
    IO.puts("playChannelTrack! #{inspect(track["name"])} - #{inspect(track["artist"]["name"])}")
    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelUserStatus", "params" => params}, state) do
    IO.puts("updateChannelUserStatus! #{inspect(params)}")
    {:ok, state}
  end

  def handle_message(%{"method" => "updateChannelDjs", "params" => params}, state) do
    IO.puts("updateChannelDjs! #{inspect(params["djs"])}")
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
end
