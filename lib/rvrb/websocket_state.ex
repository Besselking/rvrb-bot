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
          doped: boolean(),
          starred: boolean(),
          current_track: map(),
          current_track_started_at: integer() | nil,
          queue: [map()],
          channel_id: String.t() | nil
        }

  defstruct djs: [],
            doped: false,
            starred: false,
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
end
