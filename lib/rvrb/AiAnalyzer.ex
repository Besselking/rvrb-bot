defmodule Rvrb.AiAnalyzer do
  @moduledoc """
  Basic Spotify artist info, plus a heuristic guess at whether an artist is
  an AI-generated "spam" project based on how many albums/singles they've
  put out since 2024. Real artists rarely self-release more than a handful
  of records a year; AI spam accounts on Spotify are often characterized by
  dozens to hundreds of low-effort releases in a short span.

  Raw release count alone is a weak signal on its own — some real artists
  and labels are just genuinely prolific. So the verdict also weighs
  cadence: an artist who's kept up a similarly high pace since long before
  2024 is treated as "that's just their normal output", while one whose
  release rate suddenly spiked starting in 2024 (or who has no releases
  before then at all) is treated as more suspicious.

  Note: `Rvrb.SpotifyServer.artist_albums/1` caps how many releases it
  fetches, so an artist with an especially deep catalog may have their
  earliest release (and therefore their pre-2024 cadence) underestimated.
  """

  alias Rvrb.SpotifyServer

  @spam_release_threshold 20
  @prolific_release_threshold 8
  @since_year 2024
  # recent cadence at least this many times the pre-2024 cadence bumps the verdict up a level
  @cadence_surge_multiplier 4
  # recent cadence at or below this multiple of the pre-2024 cadence bumps the verdict down a level
  @cadence_steady_multiplier 1.5
  @levels [:unlikely, :possible, :likely]

  def analyze(%{"id" => artist_id}) do
    artist = SpotifyServer.artist(artist_id)
    albums = SpotifyServer.artist_albums(artist_id)

    recent_count = releases_since(albums, @since_year)
    prior_count = releases_before(albums, @since_year)
    earliest_year = earliest_release_year(albums)
    ratio = cadence_ratio(prior_count, earliest_year, recent_count)

    %{
      name: artist.name,
      genres: artist.genres || [],
      popularity: artist.popularity,
      followers: get_in(artist.followers, ["total"]),
      spotify_url: get_in(artist.external_urls, ["spotify"]),
      recent_release_count: recent_count,
      prior_release_count: prior_count,
      ai_verdict: verdict(recent_count, prior_count, ratio)
    }
  end

  @doc "Counts how many of `albums` (maps with a \"release_date\" key) were released in or after `year`."
  def releases_since(albums, year) do
    Enum.count(albums, &(release_year(&1["release_date"]) >= year))
  end

  @doc "Counts how many of `albums` were released before `year` (releases with an unknown date don't count)."
  def releases_before(albums, year) do
    Enum.count(albums, fn album ->
      release_year = release_year(album["release_date"])
      release_year > 0 and release_year < year
    end)
  end

  @doc "The earliest known release year among `albums`, or `nil` if none have a usable date."
  def earliest_release_year(albums) do
    albums
    |> Enum.map(&release_year(&1["release_date"]))
    |> Enum.reject(&(&1 == 0))
    |> case do
      [] -> nil
      years -> Enum.min(years)
    end
  end

  @doc "Extracts the leading year from a Spotify release_date (which may be YYYY, YYYY-MM or YYYY-MM-DD)."
  def release_year(release_date) when is_binary(release_date) do
    case Integer.parse(release_date) do
      {year, _rest} -> year
      :error -> 0
    end
  end

  def release_year(_release_date), do: 0

  @doc """
  Compares release cadence since `#{@since_year}` to cadence before it.
  Returns a ratio (recent releases/year ÷ prior releases/year), or `nil`
  when there's no prior release to establish a baseline against.
  """
  def cadence_ratio(prior_count, earliest_year, recent_count, current_year \\ Date.utc_today().year)

  def cadence_ratio(prior_count, _earliest_year, _recent_count, _current_year)
      when prior_count <= 0,
      do: nil

  def cadence_ratio(_prior_count, nil, _recent_count, _current_year), do: nil

  def cadence_ratio(prior_count, earliest_year, recent_count, current_year) do
    years_before = max(@since_year - earliest_year, 1)
    years_since = max(current_year - @since_year + 1, 1)

    prior_cadence = prior_count / years_before
    recent_cadence = recent_count / years_since

    recent_cadence / prior_cadence
  end

  @doc "Classifies an artist's AI-spam likelihood from their recent release count and cadence change."
  def verdict(recent_count, prior_count, cadence_ratio) do
    level =
      recent_count
      |> base_level()
      |> adjust_for_cadence(cadence_ratio)

    %{level: level, label: label(level, recent_count, prior_count, cadence_ratio)}
  end

  defp base_level(count) when count >= @spam_release_threshold, do: :likely
  defp base_level(count) when count >= @prolific_release_threshold, do: :possible
  defp base_level(_count), do: :unlikely

  defp adjust_for_cadence(level, nil), do: level
  defp adjust_for_cadence(level, ratio) when ratio >= @cadence_surge_multiplier, do: shift(level, 1)
  defp adjust_for_cadence(level, ratio) when ratio <= @cadence_steady_multiplier, do: shift(level, -1)
  defp adjust_for_cadence(level, _ratio), do: level

  defp shift(level, delta) do
    index = Enum.find_index(@levels, &(&1 == level))
    new_index = (index + delta) |> max(0) |> min(length(@levels) - 1)
    Enum.at(@levels, new_index)
  end

  defp label(level, recent_count, prior_count, cadence_ratio) do
    emoji_and_text(level) <> " (" <> context(recent_count, prior_count, cadence_ratio) <> ")"
  end

  defp emoji_and_text(:likely), do: "🤖 likely AI spam"
  defp emoji_and_text(:possible), do: "🤔 worth a second look"
  defp emoji_and_text(:unlikely), do: "🎧 looks normal"

  defp context(recent_count, 0, _cadence_ratio) do
    "#{recent_count} releases since #{@since_year}, none before then"
  end

  defp context(recent_count, _prior_count, nil) do
    "#{recent_count} releases since #{@since_year}"
  end

  defp context(recent_count, _prior_count, cadence_ratio) do
    "#{recent_count} releases since #{@since_year}, #{format_ratio(cadence_ratio)}x their pre-#{@since_year} pace"
  end

  defp format_ratio(ratio) do
    :erlang.float_to_binary(ratio, decimals: 1)
  end
end
