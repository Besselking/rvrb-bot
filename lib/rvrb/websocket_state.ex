defmodule Rvrb.WebSocket.State do
  @moduledoc """
  The state `Rvrb.WebSocket` carries across the connection's lifetime.

  It's a struct rather than a plain map so that the full set of keys is
  declared in one place: a handler that pattern matches on a key that
  isn't here, or updates one with `%{state | ...}`, fails at compile time
  instead of silently never matching. A `%{autodope: true}` clause lived
  in `handle_message/2` for exactly that reason - nothing ever set the
  key, so the branch never ran.

  Keys only belong here if something reads them. `:latency` (from every
  `keepAwake`) and `:last_deletion` (from bot chat-deletion alerts) were
  written and never read, so they're gone; `:current_play_id` now lives
  in `Rvrb.PlayWriter`, which owns vote attribution.
  """

  @type t :: %__MODULE__{
          djs: [String.t()],
          bots: MapSet.t(String.t()),
          doped: boolean(),
          starred: boolean(),
          dopes: [String.t()],
          stars: [String.t()],
          current_track: map(),
          current_track_started_at: integer() | nil,
          queue: [map()],
          channel_id: String.t() | nil
        }

  defstruct djs: [],
            # RVRB ids of every bot seen in the room, accumulated from
            # `updateChannelUsers`. Bots in the DJ queue are left out of the
            # auto-vote's unanimity check - see `Rvrb.AutoVote`.
            bots: MapSet.new(),
            doped: false,
            starred: false,
            # Who has doped/starred the current track, as of the last meter.
            # Kept so a DJ joining or leaving can be re-checked against the
            # room's votes without waiting for the next meter to arrive.
            dopes: [],
            stars: [],
            # The raw RVRB track that's playing right now, `%{}` until the
            # first `playChannelTrack` lands.
            current_track: %{},
            # Monotonic ms at which the current track started, so `\rotation`
            # can subtract the elapsed part of it from its estimate. Monotonic
            # rather than wall clock because it's only ever used as an
            # interval, and nil until we've actually seen a track start.
            current_track_started_at: nil,
            # Tracks queued with `\queue`, handed to RVRB one at a time when
            # it asks for the bot's next track.
            queue: [],
            # The channel the bot joined, from the `ready` push.
            channel_id: nil

  @doc """
  A plain-map view of the parts of the connection's state that are worth
  reporting outside it - what's playing, who's DJing, how the room has
  voted on it. Backs `Rvrb.Stats.snapshot/0`, which is read over
  distribution by anything that wants to show the room's live state
  without being in the room.

  Deliberately a projection rather than the struct itself: the raw RVRB
  track carries a few kilobytes of Spotify metadata nobody outside needs,
  and a reader shouldn't be coupled to the struct's field names. Names
  aren't resolved here either - `djs`, `dopes` and `stars` stay RVRB ids,
  because the lookup that turns them into names is a database query and
  this runs on the socket process.
  """
  def snapshot(%__MODULE__{} = state) do
    %{
      channel_id: state.channel_id,
      djs: state.djs,
      current_track: track_summary(state.current_track),
      elapsed_ms: elapsed_track_ms(state),
      remaining_ms: remaining_track_ms(state),
      dopes: state.dopes,
      stars: state.stars,
      auto_doped: state.doped,
      auto_starred: state.starred,
      queued_tracks: length(state.queue),
      known_bots: MapSet.size(state.bots)
    }
  end

  @doc """
  How much of the current track is left, or nil if we can't tell - the
  track carried no duration, or the bot came up mid-track and never saw
  this one start.
  """
  def remaining_track_ms(%__MODULE__{} = state) do
    with elapsed_ms when is_integer(elapsed_ms) <- elapsed_track_ms(state),
         duration_ms when is_integer(duration_ms) <-
           Rvrb.PlayTracker.duration_ms(state.current_track) do
      max(duration_ms - elapsed_ms, 0)
    else
      _unknown -> nil
    end
  end

  @doc """
  How far into the current track we are, or nil if we never saw it start.
  """
  def elapsed_track_ms(%__MODULE__{current_track_started_at: nil}), do: nil

  def elapsed_track_ms(%__MODULE__{current_track_started_at: started_at}),
    do: max(System.monotonic_time(:millisecond) - started_at, 0)

  # The handful of fields worth carrying out of a raw RVRB track. `%{}` -
  # nothing has played yet - stays nil rather than becoming an empty
  # summary, so a reader can tell the two apart.
  defp track_summary(track) when map_size(track) == 0, do: nil

  defp track_summary(track) do
    %{
      spotify_track_id: track["id"],
      name: track["name"],
      artist_names: Enum.map(track["artists"] || [], & &1["name"]),
      duration_ms: Rvrb.PlayTracker.duration_ms(track),
      album_art: Rvrb.Commands.album_art(track)
    }
  end
end
