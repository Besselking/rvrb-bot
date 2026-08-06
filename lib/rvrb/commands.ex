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
  alias Rvrb.Play
  alias Rvrb.PlayTracker
  alias Rvrb.Rotation
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
      name: "rotation",
      usage: "\\rotation",
      description:
        "Estimate how long a lap of the DJ queue takes, and when you're next up if you're DJing.",
      handler: &__MODULE__.rotation/3
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
      name: "skip",
      usage: "\\skip",
      description: "Use your one-time first-DJ skip to jump to the front of the queue.",
      handler: &__MODULE__.skip/3
    },
    %{
      name: "stats",
      usage: "\\stats [@user]",
      description:
        "Show DJ stats (tracks played, dopes/favorites received, favorite DJs and tracks) for yourself or a tagged user.",
      handler: &__MODULE__.stats/3
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
    table = Html.table(@commands, [{:usage, "Command"}, {:description, "Description"}])
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

    rows =
      for dj <- current_djs do
        last_djed = User.get_last_djed(dj_map, dj)

        %{
          name: User.get_name(dj_map, dj),
          last_djed: if(last_djed != nil, do: Timex.from_now(last_djed), else: ""),
          created_date: Timex.from_now(User.get_created_date(dj_map, dj)),
          used_skip: if(User.get_received_skip(dj_map, dj), do: "✅", else: "❌")
        }
      end

    table =
      Html.table(rows, [
        {:name, "Name"},
        {:last_djed, "Last DJed"},
        {:created_date, "Member Since"},
        {:used_skip, "Used first-time skip"}
      ])

    WebSocket.chat(table)
    {:ok, state}
  end

  def rotation(_args, params, state) do
    case state.djs do
      [] ->
        WebSocket.chat("Nobody's DJing right now, so there's no rotation to estimate.")

      djs ->
        estimate =
          Rotation.estimate(djs, dj_averages(djs),
            remaining_ms: remaining_track_ms(state),
            fallback_ms: Play.average_duration()
          )

        WebSocket.chat(rotation_table(estimate, User.get_users(djs), params["userId"]))
    end

    {:ok, state}
  end

  # Average track length per DJ, keyed by the RVRB ids `state.djs` uses
  # rather than the internal user ids the plays table is keyed by. DJs the
  # bot has never seen as users map to nil, which `Rvrb.Rotation` reads as
  # "no history, use the fallback".
  defp dj_averages(djs) do
    user_ids = User.get_ids(djs)
    averages = Play.average_durations(Map.values(user_ids))

    Map.new(user_ids, fn {rvrb_id, user_id} -> {rvrb_id, averages[user_id]} end)
  end

  # How much of the current track is left, or nil if we can't tell - the
  # track carried no duration, or the bot came up mid-track and never saw
  # this one start.
  defp remaining_track_ms(state) do
    started_at = Map.get(state, :current_track_started_at)
    duration_ms = PlayTracker.duration_ms(Map.get(state, :current_track))

    if is_integer(started_at) and is_integer(duration_ms) do
      max(duration_ms - (System.monotonic_time(:millisecond) - started_at), 0)
    end
  end

  @doc """
  Renders an `Rvrb.Rotation.estimate/3` result as a chat table, using
  `dj_map` (from `Rvrb.User.get_users/1`) for names, and closes with where
  `user_id` stands in the queue.

  Every number here is a guess built on averages, so the whole table is
  hedged with "≈" - a DJ who follows a 90 second interlude with a 12
  minute live set will blow through any estimate we print.
  """
  def rotation_table(%{entries: entries, total_ms: total_ms} = estimate, dj_map, user_id) do
    rows =
      for entry <- entries do
        %{
          dj: dj_label(entry, dj_map),
          track_length: track_length_label(entry),
          next_play: "≈ #{Rotation.format_ms(entry.wait_ms)}"
        }
      end

    table =
      Html.table(
        rows,
        [{:dj, "DJ"}, {:track_length, "Avg track"}, {:next_play, "Next play in"}],
        title: "DJ rotation - one lap ≈ #{Rotation.format_ms(total_ms)}"
      )

    table <> "<br/>" <> your_turn_line(estimate, user_id)
  end

  defp dj_label(%{dj: dj, current?: true}, dj_map), do: "▶ #{dj_name(dj_map, dj)}"
  defp dj_label(%{dj: dj}, dj_map), do: dj_name(dj_map, dj)

  defp dj_name(dj_map, dj), do: User.get_name(dj_map, dj) || "someone"

  defp track_length_label(%{duration_ms: duration_ms, measured?: false}) do
    "#{Rotation.format_ms(duration_ms)} (guess)"
  end

  defp track_length_label(%{duration_ms: duration_ms, play_count: play_count}) do
    "#{Rotation.format_ms(duration_ms)} (over #{pluralize(play_count, "play")})"
  end

  defp your_turn_line(estimate, user_id) do
    case Rotation.entry_for(estimate, user_id) do
      nil ->
        "You're not in the DJ queue, so there's nothing lined up for you."

      %{current?: true, wait_ms: wait_ms} ->
        "You're playing right now - you're back up in ≈ #{Rotation.format_ms(wait_ms)}."

      %{wait_ms: wait_ms} ->
        "You're up in ≈ #{Rotation.format_ms(wait_ms)}."
    end
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

  def join(_args, _params, state) do
    WebSocket.send_message(%{method: "joinDjs"})
    {:ok, state}
  end

  def artist(_args, _params, state) do
    case state.current_track["artists"] do
      artists when is_list(artists) and artists != [] ->
        rows = for artist <- artists, do: artist_row(AiAnalyzer.analyze(artist))

        table =
          Html.table(rows, [
            {:artist, "Artist"},
            {:genres, "Genres"},
            {:popularity, "Popularity"},
            {:followers, "Followers"},
            {:ai_verdict, "AI spam guess"}
          ])

        WebSocket.chat(table)

      _no_track ->
        WebSocket.chat("No track is currently playing.")
    end

    {:ok, state}
  end

  defp artist_row(%{ai_verdict: %{label: verdict_label}} = info) do
    %{
      artist: artist_link(info),
      genres: if(info.genres == [], do: "—", else: Enum.join(info.genres, ", ")),
      popularity: to_string(info.popularity),
      followers: format_followers(info.followers),
      ai_verdict: verdict_label
    }
  end

  defp artist_link(%{spotify_url: nil, name: name}), do: name

  defp artist_link(%{spotify_url: url, name: name}),
    do: "<a href=\"#{url}\" target=\"_blank\">#{name}</a>"

  defp format_followers(nil), do: "?"

  defp format_followers(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
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

  def stats("", %{"userId" => user_id}, state) do
    render_stats(User.get(user_id), "You don't have any stats yet - stick around a bit!", state)
  end

  def stats(args, _params, state) do
    case parse_tagged_username(args) do
      nil ->
        WebSocket.chat(
          "Tag someone with @ to see their stats, or use \\stats alone for your own."
        )

        {:ok, state}

      username ->
        render_stats(
          User.get_by_user_name(username),
          "No stats for #{username} yet - haven't seen them DJ.",
          state
        )
    end
  end

  @doc """
  RVRB renders an @-tag in chat as `<span class="username Bess">@Bess 🐸 </span>` -
  "Bess" (the class) is the stable username, "Bess 🐸" (the text) is the
  display name, which can contain emoji/spaces and isn't a reliable lookup
  key. Falls back to treating the raw args as a plain "@username" or
  "username" for people who type the command by hand instead of tagging.
  Returns `nil` if no username could be found either way.
  """
  @tag_regex ~r/class="username ([^"]+)"/

  def parse_tagged_username(args) do
    case Regex.run(@tag_regex, args) do
      [_match, username] -> username
      nil -> args |> String.trim() |> String.trim_leading("@") |> non_empty()
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(str), do: str

  defp render_stats(nil, not_found_message, state) do
    WebSocket.chat(not_found_message)
    {:ok, state}
  end

  defp render_stats(user, _not_found_message, state) do
    WebSocket.chat(stats_table(user, Play.stats_for(user.id)))
    {:ok, state}
  end

  @doc """
  Renders `user`'s `Rvrb.Play.stats_for/1` map as a chat table, grouped
  into who they are (Profile), what they've played (Behind the
  decks) and what they've voted for (In the crowd) - the list had gotten
  long enough that a flat one was hard to scan.

  RVRB calls a star a star over the wire but a favorite in its UI, so
  every star-derived label here says "favorite".
  """
  def stats_table(user, play_stats) do
    member_since = if user.created_date, do: Timex.from_now(user.created_date), else: "?"
    last_djed = if user.last_djed, do: Timex.from_now(user.last_djed), else: "never"
    has_skipped = if user.received_skip, do: "✅", else: "❌"

    rows = [
      %{section: "Profile"},
      %{label: "Member since", value: member_since},
      %{label: "Last DJed", value: last_djed},
      %{label: "Used first-time skip", value: has_skipped},
      %{section: "<span class=\"alert\">Behind the decks</span>"},
      %{label: "Tracks played", value: to_string(play_stats.play_count)},
      %{label: "Dopes received", value: to_string(play_stats.dopes_received)},
      %{label: "Favorites received", value: to_string(play_stats.stars_received)},
      %{label: "Most played track", value: most_played_summary(play_stats.most_played)},
      %{label: "Highest scoring track", value: track_score_summary(play_stats.best_play)},
      %{
        label: "Most played artist",
        value: most_played_artist_summary(play_stats.most_played_artist)
      },
      %{label: "Highest scoring artist", value: artist_score_summary(play_stats.best_artist)},
      %{section: "<span class=\"alert\">In the crowd</span>"},
      %{label: "Favorite DJ", value: favorite_dj_summary(play_stats.favorite_dj)},
      %{label: "Favorite track", value: track_score_summary(play_stats.favorite_track)},
      %{label: "Favorite artist", value: artist_score_summary(play_stats.favorite_artist)}
    ]

    Html.table(rows, [{:label, nil}, {:value, nil}], title: "#{display_name(user)}'s stats")
  end

  defp display_name(%{display_name: display_name}) when display_name not in [nil, ""],
    do: display_name

  defp display_name(%{user_name: user_name}), do: user_name

  defp most_played_summary(nil), do: "—"

  defp most_played_summary(%{track_name: name, artist_names: artists, play_count: count}) do
    "#{track_summary(name, artists)} (#{count}×)"
  end

  defp track_score_summary(nil), do: "—"

  defp track_score_summary(%{track_name: name, artist_names: artists} = play) do
    "#{track_summary(name, artists)} — #{score_summary(play)}"
  end

  defp track_summary(name, artists) when is_list(artists) and artists != [] do
    "#{name} — #{Enum.join(artists, ", ")}"
  end

  defp track_summary(name, _artists), do: name

  defp most_played_artist_summary(nil), do: "—"

  defp most_played_artist_summary(%{artist_name: artist_name, play_count: count}) do
    "#{artist_name} (#{count}×)"
  end

  defp artist_score_summary(nil), do: "—"

  defp artist_score_summary(%{artist_name: artist_name, score: score}) do
    "#{artist_name} — #{score} pts"
  end

  defp favorite_dj_summary(nil), do: "—"

  defp favorite_dj_summary(dj), do: "#{display_name(dj)} — #{score_summary(dj)}"

  # "Star" is what the backend calls them; the room calls them favorites.
  defp score_summary(%{score: score, dopes: dopes, stars: stars}) do
    "#{pluralize(score, "pt")} (#{pluralize(dopes, "dope")}, #{pluralize(stars, "favorite")})"
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"
end
