defmodule Rvrb.AiAnalyzer do
  @moduledoc """
  Basic Spotify artist info, plus a heuristic guess at whether an artist is
  an AI-generated "spam" project based on how much they've released since
  2024. Real artists rarely self-release more than a handful of records a
  year; AI spam accounts on Spotify are often characterized by dozens to
  hundreds of low-effort releases in a short span.

  Releases are weighted by track count rather than counted 1-for-1: a
  couple of one-track singles is a lot less content (and a lot less
  effort) than a full album or EP, so it shouldn't score the same. Spotify
  only distinguishes "album" / "single" / "compilation" at the API level
  (no separate "EP" type — those get filed as one of the other two
  depending on length), so track count is what actually tells a quick
  single apart from a longer EP or LP.

  Track-weighted volume alone is still a weak signal on its own, though —
  some real artists and labels are just genuinely prolific. So the verdict
  also weighs cadence: an artist who's kept up a similarly high pace since
  long before 2024 is treated as "that's just their normal output", while
  one whose release rate suddenly spiked starting in 2024 (or who has no
  releases before then at all) is treated as more suspicious.

  Note: `Rvrb.SpotifyServer.artist_albums/1` caps how many releases it
  fetches, so an artist with an especially deep catalog may have their
  earliest release (and therefore their pre-2024 cadence) underestimated.
  """

  alias Rvrb.SpotifyServer

  @since_year 2024

  # Track-weighted volume since @since_year at/above which the verdict escalates.
  @spam_track_threshold 60
  @prolific_track_threshold 40
  # A single release can't contribute more than this many tracks to its own
  # score, so one big (legitimate) deluxe edition can't dominate the count
  # the way repeated, smaller releases do.
  @max_tracks_per_release 12

  # recent cadence at least this many times the pre-2024 cadence bumps the verdict up a level
  @cadence_surge_multiplier 4
  # recent cadence at or below this multiple of the pre-2024 cadence bumps the verdict down a level
  @cadence_steady_multiplier 1.5
  @levels [:unlikely, :possible, :likely]

  def analyze(%{"id" => artist_id}) do
    artist = SpotifyServer.artist(artist_id)
    albums = SpotifyServer.artist_albums(artist_id)

    recent = release_summary(albums, &(&1 >= @since_year))
    prior = release_summary(albums, &(&1 > 0 and &1 < @since_year))
    earliest_year = earliest_release_year(albums)
    ratio = cadence_ratio(prior.track_score, earliest_year, recent.track_score)

    %{
      name: artist.name,
      genres: artist.genres || [],
      popularity: artist.popularity,
      followers: get_in(artist.followers, ["total"]),
      spotify_url: get_in(artist.external_urls, ["spotify"]),
      recent_releases: recent,
      prior_releases: prior,
      ai_verdict: verdict(recent, prior, ratio)
    }
  end

  @doc """
  Summarizes the `albums` matching `year_filter` (a function applied to
  each release's year): how many albums vs singles, and their combined
  track-weighted score (see `release_score/1`).
  """
  def release_summary(albums, year_filter) do
    matching =
      Enum.filter(albums, fn album -> year_filter.(release_year(album["release_date"])) end)

    %{
      count: length(matching),
      albums: Enum.count(matching, &(&1["album_type"] == "album")),
      singles: Enum.count(matching, &(&1["album_type"] != "album")),
      track_score: matching |> Enum.map(&release_score/1) |> Enum.sum()
    }
  end

  @doc """
  A release's contribution to the volume score: its track count, capped at
  #{@max_tracks_per_release} so one big release can't dominate the score
  the way repeated smaller ones can.
  """
  def release_score(album) do
    album
    |> Map.get("total_tracks")
    |> normalize_track_count()
    |> min(@max_tracks_per_release)
  end

  defp normalize_track_count(count) when is_integer(count) and count > 0, do: count
  defp normalize_track_count(_count), do: 1

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
  Compares track-weighted release cadence since `#{@since_year}` to
  cadence before it. Returns a ratio (recent score/year ÷ prior score/year),
  or `nil` when there's no prior release to establish a baseline against.
  """
  def cadence_ratio(prior_score, earliest_year, recent_score, current_year \\ Date.utc_today().year)

  def cadence_ratio(prior_score, _earliest_year, _recent_score, _current_year)
      when prior_score <= 0,
      do: nil

  def cadence_ratio(_prior_score, nil, _recent_score, _current_year), do: nil

  def cadence_ratio(prior_score, earliest_year, recent_score, current_year) do
    years_before = max(@since_year - earliest_year, 1)
    years_since = max(current_year - @since_year + 1, 1)

    prior_cadence = prior_score / years_before
    recent_cadence = recent_score / years_since

    recent_cadence / prior_cadence
  end

  @doc "Classifies an artist's AI-spam likelihood from their recent release volume and cadence change."
  def verdict(recent, prior, cadence_ratio) do
    level =
      recent.track_score
      |> base_level()
      |> adjust_for_cadence(cadence_ratio)

    %{level: level, label: label(level, recent, prior, cadence_ratio)}
  end

  defp base_level(track_score) when track_score >= @spam_track_threshold, do: :likely
  defp base_level(track_score) when track_score >= @prolific_track_threshold, do: :possible
  defp base_level(_track_score), do: :unlikely

  defp adjust_for_cadence(level, nil), do: level
  defp adjust_for_cadence(level, ratio) when ratio >= @cadence_surge_multiplier, do: shift(level, 1)
  defp adjust_for_cadence(level, ratio) when ratio <= @cadence_steady_multiplier, do: shift(level, -1)
  defp adjust_for_cadence(level, _ratio), do: level

  defp shift(level, delta) do
    index = Enum.find_index(@levels, &(&1 == level))
    new_index = (index + delta) |> max(0) |> min(length(@levels) - 1)
    Enum.at(@levels, new_index)
  end

  defp label(level, recent, prior, cadence_ratio) do
    emoji_and_text(level) <> "<br>(" <> context(recent, prior, cadence_ratio) <> ")"
  end

  defp emoji_and_text(:likely), do: "🤖 likely AI spam"
  defp emoji_and_text(:possible), do: "🤔 worth a second look"
  defp emoji_and_text(:unlikely), do: "🎧 looks normal"

  defp context(recent, %{count: 0}, _cadence_ratio) do
    release_breakdown(recent) <> "<br>since #{@since_year}, none before then"
  end

  defp context(recent, _prior, nil) do
    release_breakdown(recent) <> "<br>since #{@since_year}"
  end

  defp context(recent, _prior, cadence_ratio) do
    release_breakdown(recent) <>
      "<br>since #{@since_year}, #{format_ratio(cadence_ratio)}x their pre-#{@since_year} pace"
  end

  defp release_breakdown(%{count: 0}), do: "no releases"

  defp release_breakdown(%{albums: albums, singles: singles, track_score: track_score}) do
    "#{describe(albums, "album")}#{joiner(albums, singles)}#{describe(singles, "single")} (~#{trunc(track_score)} tracks)"
  end

  defp describe(0, _label), do: ""
  defp describe(count, label), do: "#{count} #{label}#{plural(count)}"

  defp joiner(0, _singles), do: ""
  defp joiner(_albums, 0), do: ""
  defp joiner(_albums, _singles), do: " + "

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp format_ratio(ratio) do
    :erlang.float_to_binary(ratio, decimals: 1)
  end
end
