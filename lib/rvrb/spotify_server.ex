defmodule Rvrb.SpotifyServer do
  @moduledoc "This module uses an `Agent` to persist the tokens"

  # spotify_ex's `Credentials` struct has no expiry field, and
  # `Spotify.AuthenticationClient.post/1` discards the `expires_in` Spotify
  # returns, so there's no way to ask the library "is this token still
  # good?". We track expiry ourselves instead. Client-credentials tokens are
  # issued with a 3600s lifetime; we treat them as stale a bit early to
  # leave room for in-flight requests near the boundary.
  @token_ttl_seconds 3300

  @doc "The `Agent` is started with no credentials and no expiry yet."
  def start_link do
    Agent.start_link(
      fn ->
        %{credentials: %Spotify.Credentials{}, expires_at: nil, related_artists?: true}
      end,
      name: CredStore
    )
  end

  defp get_state, do: Agent.get(CredStore, & &1)

  defp put_creds(creds) do
    expires_at = System.monotonic_time(:second) + @token_ttl_seconds
    Agent.update(CredStore, &%{&1 | credentials: creds, expires_at: expires_at})
  end

  defp fresh?(%{expires_at: nil}), do: false
  defp fresh?(%{expires_at: expires_at}), do: System.monotonic_time(:second) < expires_at

  @doc "Used to link the user to Spotify to kick off the auth process"
  def auth_url, do: Spotify.Authorization.url()

  @doc "`params` are passed to your callback endpoint from Spotify"
  def authenticate() do
    %{credentials: creds} = get_state()
    {:ok, new_creds} = authenticate(creds)
    # make sure to persist the credentials for later!
    put_creds(new_creds)
  end

  def authenticate(auth) do
    auth |> body_params() |> Spotify.AuthenticationClient.post()
  end

  @doc """
  Returns cached Spotify credentials, only requesting a new token when we
  don't have one yet or the cached one has (likely) expired.
  """
  def get_auth() do
    state = get_state()

    if fresh?(state) do
      state.credentials
    else
      {:ok, new_creds} = authenticate(state.credentials)
      # make sure to persist the credentials for later!
      put_creds(new_creds)
      new_creds
    end
  end

  @doc "Use the credentials to access the Spotify API through the library"
  def track(id) do
    credentials = get_auth()
    {:ok, track} = Spotify.Track.get_track(credentials, id)
    track
  end

  def album_tracks(id) do
    credentials = get_auth()
    {:ok, album_tracks} = Spotify.Album.get_album_tracks(credentials, id)
    ids = album_tracks.items |> Enum.map(& &1.id) |> Enum.join(",")
    {:ok, tracks} = Spotify.Track.get_tracks(credentials, ids: ids)
    tracks
  end

  def artist(id) do
    credentials = get_auth()
    {:ok, artist} = Spotify.Artist.get_artist(credentials, id)
    artist
  end

  # Spotify caps a single page at 50 items; this bounds how many pages we'll
  # follow so a wildly prolific artist can't send us on an unbounded crawl.
  @artist_albums_page_size 50
  @artist_albums_max_pages 5

  @doc """
  Fetches an artist's own albums and singles (excluding compilations and
  guest appearances), across up to #{@artist_albums_max_pages} pages.
  Returns plain maps with string keys (e.g. `album["release_date"]`).

  This bypasses `Spotify.Album.handle_response/1` on purpose: that helper
  builds a `%Spotify.Album{}` via `build_album/1`, which assumes every
  album has a nested `tracks` object. The "artist's albums" endpoint
  returns simplified album objects with no `tracks` key at all, which
  crashes that code path with a `BadMapError`.
  """
  def artist_albums(id) do
    credentials = get_auth()

    url =
      Spotify.Album.get_artists_albums_url(id) <>
        "?" <>
        URI.encode_query(limit: @artist_albums_page_size, include_groups: "album,single")

    fetch_pages(credentials, url, @artist_albums_max_pages, &items/1)
  end

  # Spotify caps a playlist page at 100 items. These lists run to a few
  # hundred tracks each today, so the cap is headroom rather than a limit
  # anyone is expected to hit.
  @playlist_page_size 100
  @playlist_max_pages 20

  @doc """
  Every artist credited on a public playlist's tracks, as plain maps with
  string keys (`artist["id"]`, `artist["name"]`), deduplicated by id and
  covering up to #{@playlist_max_pages} pages.

  Returns `[]` when Spotify won't answer - callers can't tell a failure
  from a genuinely empty playlist, and treat both as "no list".

  Like `artist_albums/1` this goes around `Spotify.Playlist`, for two
  reasons: its helpers still build the legacy
  `/users/:user_id/playlists/:id` URLs (the current endpoint needs no user
  id), and `fields` trims the response from full track objects down to the
  handful of artist keys actually wanted here.
  """
  def playlist_artists(id) do
    credentials = get_auth()

    url =
      "https://api.spotify.com/v1/playlists/#{id}/tracks?" <>
        URI.encode_query(
          limit: @playlist_page_size,
          fields: "next,items(track(artists(id,name)))"
        )

    credentials
    |> fetch_pages(url, @playlist_max_pages, &page_artists/1)
    |> Enum.uniq_by(& &1["id"])
  end

  @doc """
  A public playlist's display name, or `nil` if Spotify won't say.

  Read on every refresh rather than hardcoded alongside the ids, so that
  renaming one of the lists doesn't need a release.
  """
  def playlist_name(id) do
    credentials = get_auth()

    case get_json(credentials, "https://api.spotify.com/v1/playlists/#{id}?fields=name") do
      {:ok, %{"name" => name}} when is_binary(name) -> name
      _error -> nil
    end
  end

  @doc """
  Spotify's suggested related artists for `id`, as plain maps with string
  keys, or `[]` when Spotify won't say.

  Spotify deprecated this endpoint in November 2024: an app that didn't
  already have access to it gets a 403 no matter what it asks for. So this
  is a bonus signal where it works rather than something to lean on, and a
  403 is remembered for the life of the process - there's no point paying
  for a round trip that can only fail again.
  """
  def related_artists(id) do
    if Agent.get(CredStore, & &1.related_artists?) do
      fetch_related_artists(id)
    else
      []
    end
  end

  defp fetch_related_artists(id) do
    credentials = get_auth()

    case Spotify.Client.get(
           credentials,
           "https://api.spotify.com/v1/artists/#{id}/related-artists"
         ) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
        body |> JSON.decode!() |> Map.get("artists") |> List.wrap()

      {:ok, %HTTPoison.Response{status_code: 403}} ->
        Agent.update(CredStore, &%{&1 | related_artists?: false})
        []

      _error ->
        []
    end
  end

  @doc """
  The artists credited on one page of playlist items.

  A playlist item isn't always a track with artists on it: one whose track
  has since been pulled from Spotify arrives as `null`, and a podcast
  episode has no artists at all. Both simply contribute nothing.
  """
  def page_artists(page) do
    page
    |> items()
    |> Enum.flat_map(fn
      %{"track" => %{"artists" => artists}} when is_list(artists) -> artists
      _not_a_track -> []
    end)
  end

  defp items(page), do: page |> Map.get("items") |> List.wrap()

  # Walks a paged Spotify response, pulling each page through `extract` and
  # following its `next` link, up to `pages_left` pages. A page that fails
  # to come back ends the walk with whatever we already have.
  defp fetch_pages(_credentials, nil, _pages_left, _extract), do: []
  defp fetch_pages(_credentials, _url, 0, _extract), do: []

  defp fetch_pages(credentials, url, pages_left, extract) do
    case get_json(credentials, url) do
      {:ok, page} ->
        extract.(page) ++ fetch_pages(credentials, page["next"], pages_left - 1, extract)

      :error ->
        []
    end
  end

  defp get_json(credentials, url) do
    case Spotify.Client.get(credentials, url) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
        {:ok, JSON.decode!(body)}

      _error ->
        :error
    end
  end

  @doc false
  def body_params(%Spotify.Credentials{refresh_token: nil}) do
    "grant_type=client_credentials"
  end

  @doc false
  def body_params(%Spotify.Credentials{refresh_token: token}) do
    "grant_type=refresh_token&refresh_token=#{token}"
  end

  def body_params(auth, _code), do: body_params(auth)
end
