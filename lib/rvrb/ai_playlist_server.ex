defmodule Rvrb.AiPlaylistServer do
  @moduledoc """
  A cached, daily-refreshed index of the artists on community-curated
  Spotify playlists of AI-generated music, so `\\artist` can ask "has
  somebody already caught this one?" without re-reading three playlists
  (a thousand-odd tracks between them) on every command.

  `Rvrb.AiAnalyzer`'s release-volume heuristic is a guess. A hit here is
  somebody having listened and filed the artist under AI, which is much
  stronger evidence - so a listed artist short-circuits the guess rather
  than nudging it.

  These lists are maintained by hand and move slowly, so a day-old copy is
  as good as a fresh one. A refresh that fails leaves the previous copy in
  place and retries sooner: a stale index still answers almost every
  lookup, and it is only ever evidence on top of the heuristic.

  Artists are matched by Spotify id, never by name. The same AI project
  often has several Spotify profiles and name matching would catch those -
  but it would also brand a real artist who happens to share a name with
  one, and this is the kind of verdict people repeat.
  """

  use GenServer

  require Logger

  alias Rvrb.SpotifyServer

  # Community-curated lists of AI-generated music. Named, at the time of
  # writing, "Probably AI Clanker SLOP", "Suno Generated Music" and "Udio
  # Generated Music" - the display name is read from the API on each
  # refresh, so a rename doesn't need a code change here.
  @playlist_ids [
    "1VX1plT2A6rwob0SwuEkvH",
    "7pRdrM4ZyQFStXGGowzRGk",
    "0lPkLx6bo2GegvWPy8OUZN"
  ]

  @refresh_interval :timer.hours(24)
  # How soon to try again after a failed refresh, before backing off - see
  # `retry_interval/1`.
  @retry_interval :timer.minutes(30)

  # A lookup only reads a map already sitting in the server's state, so it
  # has no reason to take any time at all - this is here so that a wedged
  # server can't hold the websocket process open indefinitely.
  @call_timeout :timer.seconds(5)

  @doc """
  Starts the index.

  Options:

    * `:playlist_ids` - the playlists to index, defaulting to the three
      AI-music lists above.
    * `:spotify` - the module the fetches go through (anything exporting
      `playlist_artists/1` and `playlist_name/1`), defaulting to
      `Rvrb.SpotifyServer`. Tests pass a stub so they can exercise the
      refresh without a Spotify app.
    * `:name` - the registered name, defaulting to this module.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether `artist_id` is on one of the AI playlists.

  Returns `{:listed, playlists}` (each a `%{id: id, name: name}`), `:none`
  when the artist is on none of them, or `:unknown` when there is no index
  to check - the server isn't running, or its first fetch hasn't landed
  yet. "We haven't got the list" is a different answer from "we looked and
  they're not on it", and only the second one is evidence.
  """
  def lookup(server \\ __MODULE__, artist_id)

  def lookup(server, artist_id) when is_binary(artist_id) do
    # Callers are command handlers running in the websocket connection
    # process, where an exit drops the bot off the socket. A server that's
    # down, restarting or somehow slow is worth an "unknown" here, not the
    # connection.
    GenServer.call(server, {:lookup, artist_id}, @call_timeout)
  catch
    :exit, _reason -> :unknown
  end

  def lookup(_server, _artist_id), do: :unknown

  ## server

  @impl true
  def init(opts) do
    state = %{
      playlist_ids: Keyword.get(opts, :playlist_ids, @playlist_ids),
      spotify: Keyword.get(opts, :spotify, SpotifyServer),
      index: %{},
      loaded?: false,
      refreshing: nil,
      failures: 0
    }

    {:ok, state, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, start_refresh(state)}

  @impl true
  def handle_call({:lookup, _artist_id}, _from, %{loaded?: false} = state) do
    {:reply, :unknown, state}
  end

  @impl true
  def handle_call({:lookup, artist_id}, _from, state) do
    {:reply, lookup_in(state.index, artist_id), state}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, start_refresh(state)}

  @impl true
  def handle_info({:refreshed, pid, {:ok, index}}, %{refreshing: pid} = state) do
    Logger.info("AI playlist index refreshed: #{map_size(index)} artists")
    schedule(@refresh_interval)
    {:noreply, %{state | index: index, loaded?: true, refreshing: nil, failures: 0}}
  end

  @impl true
  def handle_info({:refreshed, pid, :error}, %{refreshing: pid} = state) do
    Logger.warning("AI playlist refresh came back empty, keeping the previous index")
    {:noreply, failed(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{refreshing: pid} = state) do
    Logger.warning("AI playlist refresh failed: #{Exception.format_exit(reason)}")
    {:noreply, failed(state)}
  end

  # Everything else: the `:normal` exit of a refresh whose result we just
  # handled, and any late word from one we've already given up on.
  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  ## index

  @doc """
  Looks `artist_id` up in an already-built `index`, as `{:listed,
  playlists}` or `:none`.
  """
  def lookup_in(index, artist_id) do
    case Map.fetch(index, artist_id) do
      {:ok, playlists} -> {:listed, playlists}
      :error -> :none
    end
  end

  @doc """
  Builds the `artist id => playlists` index out of fetched playlists, each
  a `%{id: id, name: name, artist_ids: ids}`.

  An artist who turns up on more than one of the lists keeps all of them,
  in the order the playlists were given: three separate people filing the
  same project under AI is worth showing.
  """
  def index(playlists) do
    Enum.reduce(playlists, %{}, fn playlist, index ->
      reference = %{id: playlist.id, name: playlist.name}

      playlist.artist_ids
      |> Enum.uniq()
      |> Enum.reduce(index, fn artist_id, index ->
        Map.update(index, artist_id, [reference], &(&1 ++ [reference]))
      end)
    end)
  end

  ## refreshing

  defp start_refresh(%{refreshing: pid} = state) when is_pid(pid), do: state

  defp start_refresh(%{spotify: spotify, playlist_ids: playlist_ids} = state) do
    server = self()

    # In its own process rather than the server's: a refresh reads a
    # thousand-odd tracks across a dozen requests, and `lookup/2` has to
    # keep answering from the previous index throughout. Monitored rather
    # than linked, so a Spotify outage - or a deployment with no Spotify
    # credentials at all, which `get_auth/0` raises on - costs a retry
    # instead of the cached index.
    {pid, _ref} =
      spawn_monitor(fn -> send(server, {:refreshed, self(), fetch(spotify, playlist_ids)}) end)

    %{state | refreshing: pid}
  end

  defp fetch(spotify, playlist_ids) do
    playlist_ids
    |> Enum.map(&fetch_playlist(spotify, &1))
    |> Enum.reject(&(&1.artist_ids == []))
    |> case do
      # Each of these lists runs to hundreds of tracks, so all of them
      # coming back empty means the fetch failed - not that somebody
      # emptied every one of them overnight.
      [] -> :error
      playlists -> {:ok, index(playlists)}
    end
  end

  # The name is only worth a request once the tracks have come back: an
  # empty playlist is a failed fetch, and there's nothing to label.
  defp fetch_playlist(spotify, playlist_id) do
    case spotify.playlist_artists(playlist_id) do
      [] ->
        %{id: playlist_id, name: nil, artist_ids: []}

      artists ->
        %{
          id: playlist_id,
          name: spotify.playlist_name(playlist_id),
          artist_ids: artists |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1)
        }
    end
  end

  defp failed(state) do
    failures = state.failures + 1
    schedule(retry_interval(failures))
    %{state | refreshing: nil, failures: failures}
  end

  @doc """
  How long to wait before retrying after `failures` consecutive failed
  refreshes: #{div(@retry_interval, 60_000)} minutes, doubling each time,
  and never longer than the ordinary refresh interval.

  A Spotify blip is worth another go in half an hour. A deployment with no
  Spotify credentials configured at all - which is supported, they're only
  needed for the Spotify-backed commands - fails every refresh, and
  shouldn't spend the rest of its life saying so twice an hour.
  """
  def retry_interval(failures) do
    min(@retry_interval * 2 ** min(failures - 1, 10), @refresh_interval)
  end

  defp schedule(interval), do: Process.send_after(self(), :refresh, interval)
end
