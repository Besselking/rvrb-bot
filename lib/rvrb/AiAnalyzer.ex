defmodule Rvrb.AiAnalyzer do
  @moduledoc """
  Basic Spotify artist info, plus a heuristic guess at whether an artist is
  an AI-generated "spam" project based on how many albums/singles they've
  put out since 2024. Real artists rarely self-release more than a handful
  of records a year; AI spam accounts on Spotify are often characterized by
  dozens to hundreds of low-effort releases in a short span.
  """

  alias Rvrb.SpotifyServer

  @spam_release_threshold 20
  @prolific_release_threshold 8
  @since_year 2024

  def analyze(%{"id" => artist_id}) do
    artist = SpotifyServer.artist(artist_id)
    albums = SpotifyServer.artist_albums(artist_id)
    recent_release_count = releases_since(albums, @since_year)

    %{
      name: artist.name,
      genres: artist.genres || [],
      popularity: artist.popularity,
      followers: get_in(artist.followers, ["total"]),
      spotify_url: get_in(artist.external_urls, ["spotify"]),
      recent_release_count: recent_release_count,
      ai_verdict: verdict(recent_release_count)
    }
  end

  @doc "Counts how many of `albums` (maps with a \"release_date\" key) were released in or after `year`."
  def releases_since(albums, year) do
    albums
    |> Enum.filter(&(release_year(&1["release_date"]) >= year))
    |> Enum.count()
  end

  @doc "Extracts the leading year from a Spotify release_date (which may be YYYY, YYYY-MM or YYYY-MM-DD)."
  def release_year(release_date) when is_binary(release_date) do
    case Integer.parse(release_date) do
      {year, _rest} -> year
      :error -> 0
    end
  end

  def release_year(_release_date), do: 0

  @doc "Classifies an artist's AI-spam likelihood from their recent release count."
  def verdict(count) when count >= @spam_release_threshold do
    %{level: :likely, label: "🤖 likely AI spam (#{count} releases since #{@since_year})"}
  end

  def verdict(count) when count >= @prolific_release_threshold do
    %{level: :possible, label: "🤔 unusually prolific (#{count} releases since #{@since_year})"}
  end

  def verdict(count) do
    %{level: :unlikely, label: "🎧 looks normal (#{count} releases since #{@since_year})"}
  end
end
