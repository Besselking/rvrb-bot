defmodule Rvrb.DjRestore do
  @moduledoc """
  Puts a DJ back where they were in the queue when they drop out and come
  back soon after.

  A DJ can leave the queue for plenty of reasons - a lost connection, a
  reload, an empty stack of tracks - and RVRB puts them at the back when
  they rejoin. If they are back within `window_ms/0`, this works out where
  they belong instead.

  Two spots are considered, counted from the front of the queue (`0` is the
  DJ playing now, `1` is next up):

    * the *absolute* spot - the position they dropped from, say third.
    * the *relative* spot - that position, less the tracks played since:
      third in line when they dropped, one play later, is second.

  The relative spot is the better one for the DJ, so it wins while it is
  still in front. Once enough tracks have played that it would have come
  round to them and gone past - to the back of the queue - they get the
  absolute spot they lost instead. Nobody is put at `0`: that is the track
  playing, and a DJ whose turn it would be right now goes next up.

  Pure on purpose, like `Rvrb.Rotation`: the connection hands in what it
  saw and gets back the queue it should ask RVRB for.
  """

  @window_ms :timer.minutes(10)

  @typedoc "Who dropped out recently, by RVRB id, and from where."
  @type dropped :: %{
          String.t() => %{position: non_neg_integer(), plays: non_neg_integer(), at: integer()}
        }

  @doc "How long, in milliseconds, a DJ has to come back to get their spot."
  def window_ms, do: @window_ms

  @doc """
  Takes the DJ queue change from `old_djs` to `new_djs` and returns
  `{dropped, djs}`: the updated record of who dropped out, and the queue it
  should be - `new_djs` itself unless someone rejoined inside the window.

    * `dropped` - what the last call returned (`%{}` to start).
    * `plays` - how many tracks have started so far, a counter that only
      grows.
    * `now` - a monotonic time in milliseconds.
    * `ignore` - ids whose spot is never kept, such as bots.
  """
  def update(dropped, old_djs, new_djs, plays, now, ignore \\ MapSet.new()) do
    dropped
    |> prune(now)
    |> record_drops(old_djs, new_djs, plays, now, ignore)
    |> restore(old_djs, new_djs, plays)
  end

  @doc """
  The spot, counted from the front of the queue, that a DJ who dropped with
  `entry` goes back to when `plays` tracks have started in all.
  """
  def target(%{position: position, plays: plays_then}, plays) do
    relative = position - (plays - plays_then)

    cond do
      relative >= 1 -> relative
      relative == 0 -> 1
      true -> max(position, 1)
    end
  end

  defp prune(dropped, now) do
    Map.filter(dropped, fn {_id, %{at: at}} -> now - at <= @window_ms end)
  end

  defp record_drops(dropped, old_djs, new_djs, plays, now, ignore) do
    old_djs
    |> Enum.with_index()
    |> Enum.reduce(dropped, fn {id, position}, dropped ->
      if id in new_djs or MapSet.member?(ignore, id) do
        dropped
      else
        Map.put(dropped, id, %{position: position, plays: plays, at: now})
      end
    end)
  end

  defp restore(dropped, old_djs, new_djs, plays) do
    new_djs
    |> Enum.reject(&(&1 in old_djs))
    |> Enum.reduce({dropped, new_djs}, fn id, {dropped, djs} ->
      case Map.pop(dropped, id) do
        {nil, dropped} -> {dropped, djs}
        {entry, dropped} -> {dropped, move(djs, id, target(entry, plays))}
      end
    end)
  end

  # Takes `id` out and puts them back at `spot`, but never at the front and
  # never past the end.
  defp move(djs, id, spot) do
    rest = List.delete(djs, id)
    List.insert_at(rest, rest |> length() |> min(max(spot, 1)), id)
  end
end
