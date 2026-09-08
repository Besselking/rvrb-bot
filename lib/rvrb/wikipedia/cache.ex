defmodule Rvrb.Wikipedia.Cache do
  @moduledoc """
  Remembers what `Rvrb.Wikipedia` found for an artist, so the second
  `\\artist` on a track - or the same artist coming round again later in
  the night - costs Wikipedia nothing.

  Each lookup is two or three requests against an API whose anonymous
  rate limit is lower than it looks: a burst of them earns HTTP 429s, and
  a 429 reads exactly like an artist with nothing to say. Most of that
  traffic is repeats, which is what this removes.

  Only settled answers are kept. "Here is what the article says" and
  "there is nothing to say" are both answers, and the second is the
  common one - an artist Wikipedia has never heard of shouldn't cost a
  search every time somebody types the command. A lookup that *failed* is
  not an answer and isn't stored, or one throttled minute would cost an
  artist their passages for the rest of the day.

  Entries expire (see `@ttl`) because an article gains a section
  eventually, and the table is capped (see `@max_entries`) because a room
  plays a lot of artists and this process lives as long as the bot does.

  The lookup itself runs in the caller, not here: it's HTTP, and a room's
  worth of `\\artist` traffic has no business queueing behind one
  GenServer. This only holds the map.
  """

  use GenServer

  alias Rvrb.Wikipedia

  # Long enough to cover a night in the room, short enough that an article
  # which grows a "Controversies" section is picked up the same day.
  @ttl :timer.hours(6)
  @sweep_interval :timer.hours(1)
  # Roughly a very busy month of distinct artists, at a few hundred bytes
  # each. Past this the entry closest to expiring makes way.
  @max_entries 500

  # Reading the map should take no time at all; this is here so a wedged
  # cache can't hold up a command instead.
  @call_timeout :timer.seconds(5)

  @doc """
  Starts the cache.

  Options:

    * `:ttl` - how long an answer stays good, in milliseconds.
    * `:max_entries` - how many artists to remember.
    * `:name` - the registered name, defaulting to this module.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  What Wikipedia has on `artist_name`, from the cache where it's known and
  from `Rvrb.Wikipedia` otherwise: the same `%{title:, url:, passages:}`
  that `Rvrb.Wikipedia.controversies/2` returns, or `nil` for an artist
  there's nothing to say about.

  A lookup that failed also answers `nil` - the caller prints nothing
  either way - but isn't remembered, so the next `\\artist` tries again.

  Options:

    * `:server` - the cache to use, defaulting to this module. A cache
      that isn't running is not an error: the lookup simply happens
      uncached, which is what the test environment (and a `\\artist`
      during a restart) gets.
    * `:api` - passed through to `Rvrb.Wikipedia.controversies/2`.
  """
  def controversies(artist_name, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case fetch(server, artist_name) do
      {:ok, result} -> result
      :miss -> lookup(server, artist_name, opts)
    end
  end

  defp lookup(server, artist_name, opts) do
    case lookup_result(artist_name, opts) do
      {:ok, result} ->
        GenServer.cast(server, {:put, artist_name, result})
        result

      :error ->
        nil
    end
  end

  defp lookup_result(artist_name, opts) do
    case Keyword.fetch(opts, :api) do
      {:ok, api} -> Wikipedia.controversies(artist_name, api)
      :error -> Wikipedia.controversies(artist_name)
    end
  end

  # Callers are command handlers, and a cache that's down, restarting or
  # somehow slow is worth a cache miss rather than their process.
  defp fetch(server, artist_name) do
    GenServer.call(server, {:fetch, artist_name}, @call_timeout)
  catch
    :exit, _reason -> :miss
  end

  ## server

  @impl true
  def init(opts) do
    state = %{
      entries: %{},
      ttl: Keyword.get(opts, :ttl, @ttl),
      max_entries: Keyword.get(opts, :max_entries, @max_entries)
    }

    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:fetch, artist_name}, _from, state) do
    case Map.fetch(state.entries, artist_name) do
      {:ok, {result, expires_at}} ->
        if expired?(expires_at) do
          {:reply, :miss, %{state | entries: Map.delete(state.entries, artist_name)}}
        else
          {:reply, {:ok, result}, state}
        end

      :error ->
        {:reply, :miss, state}
    end
  end

  @impl true
  def handle_cast({:put, artist_name, result}, state) do
    entries =
      state.entries
      |> evict(state.max_entries)
      |> Map.put(artist_name, {result, now() + state.ttl})

    {:noreply, %{state | entries: entries}}
  end

  @impl true
  def handle_info(:sweep, state) do
    entries =
      Map.reject(state.entries, fn {_name, {_result, expires_at}} -> expired?(expires_at) end)

    schedule_sweep()
    {:noreply, %{state | entries: entries}}
  end

  # Room for the entry about to be added: the one closest to expiring goes,
  # which is the one that has been sitting there longest.
  defp evict(entries, max_entries) when map_size(entries) < max_entries, do: entries

  defp evict(entries, max_entries) do
    {name, _entry} = Enum.min_by(entries, fn {_name, {_result, expires_at}} -> expires_at end)

    entries
    |> Map.delete(name)
    |> evict(max_entries)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp expired?(expires_at), do: now() >= expires_at

  # Monotonic, so the cache doesn't outlive its welcome (or expire
  # everything at once) because the system clock moved.
  defp now, do: System.monotonic_time(:millisecond)
end
