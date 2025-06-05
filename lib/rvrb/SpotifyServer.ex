defmodule Rvrb.SpotifyServer do
  @moduledoc "This module uses an `Agent` to persist the tokens"
  @doc "The `Agent` is started with an empty `Credentials` struct"
  def start_link do
    Agent.start_link(fn -> %Spotify.Credentials{} end, name: CredStore)
  end

  defp get_creds, do: Agent.get(CredStore, & &1)

  defp put_creds(creds), do: Agent.update(CredStore, fn _ -> creds end)

  @doc "Used to link the user to Spotify to kick off the auth process"
  def auth_url, do: Spotify.Authorization.url()

  @doc "`params` are passed to your callback endpoint from Spotify"
  def authenticate() do
    creds = get_creds()
    {:ok, new_creds} = authenticate(creds)
    # make sure to persist the credentials for later!
    put_creds(new_creds)
  end

  def authenticate(auth) do
    auth |> body_params() |> Spotify.AuthenticationClient.post()
  end

  @doc "Use the credentials to access the Spotify API through the library"
  def track(id) do
    credentials = get_creds()
    {:ok, track} = Spotify.Track.get_track(credentials, id)
    track
  end

  def album_tracks(id) do
    credentials = get_creds()
    {:ok, album_tracks} = Spotify.Album.get_album_tracks(credentials, id)
    ids = album_tracks.items |> Enum.map(&(&1.id)) |> Enum.join(",")
    {:ok, tracks} = Spotify.Track.get_tracks(credentials, ids: ids)
    tracks
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
