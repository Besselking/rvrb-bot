defmodule Rvrb.Commands do
  @moduledoc """
  Parsing and dispatch for `\\`-prefixed chat commands.

  Keeping this separate from `Rvrb.WebSocket` means the command registry,
  argument parsing, and handler logic can be read/tested/changed without
  touching the Fresh connection/GenServer plumbing. Handlers still talk to
  the socket through `Rvrb.WebSocket.chat/1` and `Rvrb.WebSocket.send_message/1`
  since sending a reply is inherently tied to the live connection.
  """

  alias Rvrb.AiAnalyzer
  alias Rvrb.GenreServer
  alias Rvrb.SpotifyServer
  alias Rvrb.SpotifyUrl
  alias Rvrb.User
  alias Rvrb.WebSocket

  @prefix "\\"

  @commands [
    %{
      name: "help",
      usage: "\\help [command]",
      description: "List available commands, or show usage for one command.",
      handler: &__MODULE__.help/3
    },
    %{
      name: "qg",
      usage: "\\qg [keyword]",
      description: "Suggest a random genre, optionally filtered to genres containing keyword.",
      handler: &__MODULE__.qg/3
    },
    %{
      name: "djs",
      usage: "\\djs",
      description: "Show the DJ queue with last-DJed time, membership date and skip status.",
      handler: &__MODULE__.djs/3
    },
    %{
      name: "spin",
      usage: "\\spin",
      description: "Post a spinning animation of the current track's album art.",
      handler: &__MODULE__.spin/3
    },
    %{
      name: "queue",
      usage: "\\queue [spotify track/album url]",
      description: "Show the upcoming track queue, or (admins only) queue a Spotify URL.",
      handler: &__MODULE__.queue/3
    },
    %{
      name: "whisperback",
      usage: "\\whisperback",
      description: "Whisper a test message back to you.",
      handler: &__MODULE__.whisperback/3
    },
    %{
      name: "join",
      usage: "\\join",
      description: "Have the bot join the DJ queue.",
      handler: &__MODULE__.join/3
    },
    %{
      name: "artist",
      usage: "\\artist",
      description:
        "Show Spotify info for the currently playing track's artist(s), plus a guess at whether they're an AI spam project.",
      handler: &__MODULE__.artist/3
    },
    %{
      name: "related",
      usage: "\\related",
      description: "Show artists similar to the currently playing track's artist.",
      handler: &__MODULE__.related/3
    },
    %{
      name: "skip",
      usage: "\\skip",
      description: "Use your one-time first-DJ skip to jump to the front of the queue.",
      handler: &__MODULE__.skip/3
    }
  ]

  @doc "Returns the registered commands, in definition order."
  def commands, do: @commands

  @doc """
  Parses a chat payload into `{:ok, name, args}`, where `name` is the
  lowercased command word (without the `\\` prefix) and `args` is the
  trimmed remainder of the message (`""` if none was given). Returns
  `:error` if `payload` isn't a command.
  """
  def parse(payload) when is_binary(payload) do
    trimmed = String.trim(payload)

    if String.starts_with?(trimmed, @prefix) do
      trimmed
      |> String.trim_leading(@prefix)
      |> String.split(" ", parts: 2)
      |> case do
        [name] -> {:ok, String.downcase(name), ""}
        [name, args] -> {:ok, String.downcase(name), String.trim(args)}
      end
    else
      :error
    end
  end

  def parse(_payload), do: :error

  @doc """
  Parses and dispatches a chat payload. Returns `:not_a_command` when
  `payload` isn't a `\\` command, so the caller can fall back to its own
  default handling (e.g. logging).
  """
  def handle(payload, params, state) do
    case parse(payload) do
      {:ok, name, args} -> dispatch(name, args, params, state)
      :error -> :not_a_command
    end
  end

  defp dispatch(name, args, params, state) do
    case Enum.find(@commands, &(&1.name == name)) do
      nil ->
        WebSocket.chat("Unknown command \\#{name}. Try \\help for a list of commands.")
        {:ok, state}

      %{handler: handler} ->
        IO.puts("command \\#{name} #{args}")
        handler.(args, params, state)
    end
  end

  defp admin?(user_id) do
    admins = Application.get_env(:rvrb, :bot_admins)
    Enum.member?(admins, user_id)
  end

  ## -- handlers --------------------------------------------------------

  def help("", _params, state) do
    rows =
      for %{usage: usage, description: description} <- @commands do
        "<tr><td>#{usage}</td><td>#{description}</td></tr>"
      end

    table = "<table class=\"chat-table striped\">
      <thead>
        <tr><th>Command</th><th>Description</th></tr>
      </thead>
      <tbody>#{Enum.join(rows)}</tbody>
    </table>"

    WebSocket.chat(table)
    {:ok, state}
  end

  def help(name, _params, state) do
    case Enum.find(@commands, &(&1.name == String.downcase(name))) do
      nil ->
        WebSocket.chat("Unknown command \\#{name}. Try \\help for a list of commands.")

      %{usage: usage, description: description} ->
        WebSocket.chat("<strong>#{usage}</strong> - #{description}")
    end

    {:ok, state}
  end

  def qg("", _params, state) do
    WebSocket.chat(GenreServer.get_genre())
    {:ok, state}
  end

  def qg(keyword, _params, state) do
    WebSocket.chat(GenreServer.get_genre(keyword))
    {:ok, state}
  end

  def djs(_args, _params, state) do
    current_djs = state.djs
    dj_map = User.get_users(current_djs)

    djs =
      for dj <- current_djs do
        {User.get_name(dj_map, dj), User.get_last_djed(dj_map, dj),
         User.get_created_date(dj_map, dj), User.get_received_skip(dj_map, dj)}
      end

    rows =
      for {name, last_djed, created_date, received_skip} <- djs do
        relative_date = if last_djed != nil, do: Timex.from_now(last_djed), else: ""
        has_skipped = if received_skip, do: "✅", else: "❌"

        "<tr><td>#{name}</td><td>#{relative_date}</td><td>#{Timex.from_now(created_date)}</td><td>#{has_skipped}</td></tr>"
      end

    table = "<table class=\"chat-table striped\">
      <thead>
        <tr><th>Name</th><th>Last DJed</th><th>Member Since</th><th>Used first-time skip</th></tr>
      </thead>
      <tbody>#{Enum.join(rows)}</tbody>
    </table>"

    WebSocket.chat(table)
    {:ok, state}
  end

  def spin(_args, _params, state) do
    track = state.current_track
    album_art = hd(track["album"]["images"])["url"]

    WebSocket.chat("<span class=\"image-container\">
      <img class=\"ui image circular spin\" src=\"#{album_art}\"/>
    </span>")

    {:ok, state}
  end

  def queue("", _params, state) do
    WebSocket.send_queue(state.queue)
    {:ok, state}
  end

  def queue(url, %{"userId" => user_id}, state) do
    if admin?(user_id) do
      {type, id} = SpotifyUrl.parse(url)

      queue =
        state.queue ++
          case type do
            :track ->
              [SpotifyServer.track(id)]

            :album ->
              SpotifyServer.album_tracks(id)

            :error ->
              WebSocket.chat("error queuing: #{id}")
              []
          end

      WebSocket.send_queue(queue)
      {:ok, %{state | queue: queue}}
    else
      WebSocket.chat("Sorry, you're not allowed to queue tracks")
      {:ok, state}
    end
  end

  def whisperback(_args, %{"userId" => user_id}, state) do
    user = User.get(user_id)
    WebSocket.chat("/w @#{user.display_name} hi there!")
    {:ok, state}
  end

  def join(_args, _params, state) do
    WebSocket.send_message(%{method: "joinDjs"})
    {:ok, state}
  end

  def artist(_args, _params, state) do
    case state.current_track["artists"] do
      artists when is_list(artists) and artists != [] ->
        rows = for artist <- artists, do: artist_row(AiAnalyzer.analyze(artist))

        table = "<table class=\"chat-table striped\">
          <thead>
            <tr><th>Artist</th><th>Genres</th><th>Popularity</th><th>Followers</th><th>AI spam guess</th></tr>
          </thead>
          <tbody>#{Enum.join(rows)}</tbody>
        </table>"

        WebSocket.chat(table)

      _no_track ->
        WebSocket.chat("No track is currently playing.")
    end

    {:ok, state}
  end

  defp artist_row(%{ai_verdict: %{label: verdict_label}} = info) do
    genres = if info.genres == [], do: "—", else: Enum.join(info.genres, ", ")
    name = if info.spotify_url, do: "<a href=\"#{info.spotify_url}\" target=\"_blank\">#{info.name}</a>", else: info.name

    "<tr>
      <td>#{name}</td>
      <td>#{genres}</td>
      <td>#{info.popularity}</td>
      <td>#{format_followers(info.followers)}</td>
      <td>#{verdict_label}</td>
    </tr>"
  end

  defp format_followers(nil), do: "?"

  defp format_followers(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @related_artists_limit 8

  def related(_args, _params, state) do
    case state.current_track["artists"] do
      [%{"id" => artist_id, "name" => artist_name} | _rest] ->
        case SpotifyServer.related_artists(artist_id) |> Enum.take(@related_artists_limit) do
          [] ->
            WebSocket.chat("Couldn't find anyone Spotify considers similar to #{artist_name}.")

          related ->
            rows = for artist <- related, do: related_artist_row(artist)

            table = "<table class=\"chat-table striped\">
              <thead>
                <tr><th>Artists similar to #{artist_name}</th><th>Genres</th><th>Popularity</th></tr>
              </thead>
              <tbody>#{Enum.join(rows)}</tbody>
            </table>"

            WebSocket.chat(table)
        end

      _no_track ->
        WebSocket.chat("No track is currently playing.")
    end

    {:ok, state}
  end

  defp related_artist_row(%Spotify.Artist{} = artist) do
    genres = if artist.genres in [nil, []], do: "—", else: Enum.join(artist.genres, ", ")

    name =
      case get_in(artist.external_urls, ["spotify"]) do
        nil -> artist.name
        url -> "<a href=\"#{url}\" target=\"_blank\">#{artist.name}</a>"
      end

    "<tr><td>#{name}</td><td>#{genres}</td><td>#{artist.popularity}</td></tr>"
  end

  def skip(_args, %{"userId" => user_id}, state) do
    user = User.get(user_id)
    current_djs = state.djs

    cond do
      user.received_skip ->
        WebSocket.chat(
          "You've already received a skip, if you lost your position due to a disconnect ask a mod for help."
        )

      user_id not in current_djs ->
        WebSocket.chat("You have to be DJing to use \\skip")

      true ->
        djs_without = current_djs -- [user_id]

        reordered =
          case djs_without do
            [] -> [user_id]
            [current_dj] -> [current_dj, user_id]
            [current_dj | rest] -> [current_dj, user_id | rest]
          end

        if reordered == current_djs do
          WebSocket.chat("Skipping wont do anything right now.")
        else
          WebSocket.send_message(%{
            jsonrpc: "2.0",
            method: "updateDjs",
            params: %{djs: reordered}
          })

          User.update_received_skip(user)
          WebSocket.chat("You're next up!")
        end
    end

    {:ok, state}
  end
end
