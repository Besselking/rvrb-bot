defmodule Rvrb.Rotation do
  @moduledoc """
  Estimates how long a lap of the DJ queue takes, and how long each DJ has
  to wait for their next play, from the average track length of everyone
  in the queue. Backs the `\\rotation` command.

  Pure on purpose: the inputs come from the database (`Rvrb.Play.average_durations/1`)
  and from the live connection (who's in the queue, how far into the
  current track we are), but the arithmetic and formatting here can be
  read and tested without either.
  """

  # What we assume a track is worth when we have nothing at all to go on -
  # no history for the DJ, and no room history to average over either.
  @default_duration_ms 210_000

  @doc "Track length assumed for a DJ with no history, when there's no room average to fall back on."
  def default_duration_ms, do: @default_duration_ms

  @doc """
  Estimates the rotation for `djs` - the DJ queue in play order, current
  DJ first - given `averages`, a `%{dj => %{avg_ms: ms, play_count: n}}`
  map of what each DJ's tracks tend to run to (as returned by
  `Rvrb.Play.average_durations/1`, re-keyed by whatever identifies a DJ in
  `djs`). DJs missing from `averages` fall back to `:fallback_ms`, or to
  `default_duration_ms/0` when that's nil too.

  Options:

    * `:remaining_ms` - how much of the current track is left. Defaults to
      the current DJ's average, which is the best we can do if we never
      saw the track start (a bot restart mid-track, say).
    * `:fallback_ms` - assumed track length for DJs with no history.

  Returns `%{entries: [...], total_ms: ms}`, where `total_ms` is one full
  lap of the queue and each entry is:

    * `:dj` - the queue entry it was built from
    * `:duration_ms` - that DJ's assumed track length
    * `:play_count` - how many timed plays the average is drawn from (0 when assumed)
    * `:measured?` - false when `:duration_ms` is a fallback rather than that DJ's own average
    * `:current?` - true for the DJ playing right now
    * `:wait_ms` - time until that DJ's *next* play starts; for the
      current DJ that's a whole lap away, not zero

  A DJ appearing twice in `djs` (which RVRB shouldn't do, but nothing here
  depends on it not happening) gets an entry per slot, each with its own
  wait.
  """
  def estimate(djs, averages, opts \\ [])

  def estimate([], _averages, _opts), do: %{entries: [], total_ms: 0}

  def estimate(djs, averages, opts) do
    fallback_ms = Keyword.get(opts, :fallback_ms) || @default_duration_ms
    [current | upcoming] = Enum.map(djs, &entry(&1, averages[&1], fallback_ms))

    remaining_ms =
      case Keyword.get(opts, :remaining_ms) do
        nil -> current.duration_ms
        remaining_ms -> max(remaining_ms, 0)
      end

    # Everyone still to play waits out the current track plus everyone
    # queued ahead of them; the current DJ waits for all of that *and* for
    # the rest of the queue to play, since their next play closes the lap.
    {upcoming, lap_ms} =
      Enum.map_reduce(upcoming, remaining_ms, fn entry, wait_ms ->
        {Map.put(entry, :wait_ms, wait_ms), wait_ms + entry.duration_ms}
      end)

    current = %{current | current?: true} |> Map.put(:wait_ms, lap_ms)

    %{
      entries: [current | upcoming],
      total_ms: Enum.sum(Enum.map([current | upcoming], & &1.duration_ms))
    }
  end

  defp entry(dj, %{avg_ms: avg_ms, play_count: play_count}, _fallback_ms)
       when is_integer(avg_ms) and avg_ms > 0 do
    %{dj: dj, duration_ms: avg_ms, play_count: play_count, measured?: true, current?: false}
  end

  defp entry(dj, _no_average, fallback_ms) do
    %{dj: dj, duration_ms: fallback_ms, play_count: 0, measured?: false, current?: false}
  end

  @doc """
  The entry for `dj` in an `estimate/3` result, or nil if they're not in
  the queue.
  """
  def entry_for(%{entries: entries}, dj), do: Enum.find(entries, &(&1.dj == dj))

  @doc """
  Renders a duration in milliseconds as a short human string ("42s",
  "3m 20s", "1h 4m"). `nil` renders as "?", and negative values - a track
  that's already run past its length - as "0s".
  """
  def format_ms(nil), do: "?"

  def format_ms(ms) when is_number(ms) do
    seconds = max(div(round(ms), 1000), 0)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)

    cond do
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end
end
