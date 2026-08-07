defmodule Rvrb.PlayWriter do
  @moduledoc """
  Serializes the `plays` / `play_votes` writes that RVRB's track and meter
  events produce, so `Rvrb.WebSocket` never blocks on Postgres.

  Every write goes through this one process, in the order the socket cast
  it. That ordering is the point: `updateChannelMeter` reports the room's
  *current* vote state rather than a delta, so two meters applied out of
  order would leave the table reflecting the older one. A bare `Task` per
  event gets the socket unblocked just as well but gives up that
  guarantee.

  It also owns `current_play_id` - the play votes are attributed to -
  instead of handing it back to the socket. The insert that produces the
  id is asynchronous now, so the socket can't hold it without a round of
  messages back, and any meter arriving in that window would have nowhere
  to go. Keeping it here means a meter cast after a `record/2` is
  guaranteed to see that record's id, whether or not the insert has
  finished yet, and meters that arrive with no play recorded (no DJ, or a
  failed insert) drop the way `PlayTracker.sync_votes(nil, _)` already
  does.
  """

  use GenServer

  alias Rvrb.PlayTracker

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a play of `track` by the head of `djs`, and points subsequent
  `sync_votes/2` calls at it. Returns as soon as the message is queued.
  """
  def record(server \\ __MODULE__, djs, track) do
    GenServer.cast(server, {:record, djs, track})
  end

  @doc """
  Syncs `play_votes` for whatever play was last recorded to the room's
  current vote state, from an `updateChannelMeter` `voting` payload.
  Returns as soon as the message is queued.
  """
  def sync_votes(server \\ __MODULE__, voting) do
    GenServer.cast(server, {:sync_votes, voting})
  end

  @doc """
  The play votes are currently being attributed to, or `nil` if nothing is
  playing that we managed to record. Synchronous, so it also serves as a
  way to wait for the queued writes ahead of it.
  """
  def current_play_id(server \\ __MODULE__) do
    GenServer.call(server, :current_play_id)
  end

  @impl true
  def init(_opts), do: {:ok, %{current_play_id: nil}}

  @impl true
  def handle_cast({:record, djs, track}, state) do
    play_id = guard("record", fn -> PlayTracker.record(djs, track) end)

    {:noreply, %{state | current_play_id: play_id}}
  end

  def handle_cast({:sync_votes, voting}, state) do
    guard("sync_votes", fn -> PlayTracker.sync_votes(state.current_play_id, voting) end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:current_play_id, _from, state) do
    {:reply, state.current_play_id, state}
  end

  # A write failing (Postgres down, a row a foreign key doesn't like) costs
  # this play's stats and nothing else - it must not take the process down
  # with it, since a restart would also lose `current_play_id` and orphan
  # the rest of the track's votes.
  defp guard(what, fun) do
    fun.()
  rescue
    error ->
      IO.puts("PlayWriter #{what} failed: #{Exception.message(error)}")
      nil
  end
end
