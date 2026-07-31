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
    Agent.start_link(fn -> %{credentials: %Spotify.Credentials{}, expires_at: nil} end,
      name: CredStore
    )
  end

  defp get_state, do: Agent.get(CredStore, & &1)

  defp put_creds(creds) do
    expires_at = System.monotonic_time(:second) + @token_ttl_seconds
    Agent.update(CredStore, fn _ -> %{credentials: creds, expires_at: expires_at} end)
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

  @doc "Artists similar to the given artist, or [] if Spotify has none / errors out."
  def related_artists(id) do
    credentials = get_auth()

    case Spotify.Artist.get_related_artists(credentials, id) do
      {:ok, artists} -> artists
      _error -> []
    end
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

    fetch_albums(credentials, url, @artist_albums_max_pages)
  end

  defp fetch_albums(_credentials, nil, _pages_left), do: []
  defp fetch_albums(_credentials, _url, 0), do: []

  defp fetch_albums(credentials, url, pages_left) do
    case Spotify.Client.get(credentials, url) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
        page = JSON.decode!(body)
        items = Map.get(page, "items", [])
        items ++ fetch_albums(credentials, page["next"], pages_left - 1)

      _error ->
        []
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
