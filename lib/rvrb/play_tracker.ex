defmodule Rvrb.PlayTracker do
  @moduledoc """
  Bridges RVRB's `playChannelTrack` / `updateChannelMeter` websocket
  events into the `plays` / `play_votes` tables. Kept separate from
  `Rvrb.WebSocket` so the event -> row mapping can be read (and the pure
  parts tested) without the Fresh connection/GenServer plumbing.
  """

  alias Rvrb.Play
  alias Rvrb.PlayVote
  alias Rvrb.User

  @vote_types ~w[dope star boofstar nope]

  @doc """
  Records a play for the current DJ (the head of `djs`) and returns the
  new play's id, or `nil` if there's no DJ, they aren't a known user yet,
  or the insert fails.
  """
  def record([], _track), do: nil

  def record([dj_rvrb_id | _rest], track) do
    case User.get_ids([dj_rvrb_id])[dj_rvrb_id] do
      nil ->
        nil

      user_id ->
        case Play.record(track_attrs(track, user_id)) do
          {:ok, play} -> play.id
          {:error, _changeset} -> nil
        end
    end
  end

  @doc "Builds the attrs for a `Rvrb.Play` insert from a raw RVRB track payload."
  def track_attrs(track, user_id) do
    artists = track["artists"] || []

    %{
      user_id: user_id,
      spotify_track_id: track["id"],
      track_name: track["name"],
      artist_names: Enum.map(artists, & &1["name"]),
      spotify_artist_ids: Enum.map(artists, & &1["id"]),
      duration_ms: duration_ms(track),
      played_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }
  end

  @doc """
  Track length in milliseconds from a raw RVRB track payload, or `nil` if
  it doesn't carry one.

  RVRB passes Spotify's track object through, so `duration_ms` is the key
  that's normally there; a bare `duration` is accepted as a fallback, in
  seconds if it's too small to plausibly be milliseconds (under a second
  would be no track at all).
  """
  def duration_ms(track) when is_map(track) do
    case track["duration_ms"] || track["duration"] do
      duration when is_number(duration) and duration >= 1000 -> round(duration)
      duration when is_number(duration) and duration > 0 -> round(duration * 1000)
      _missing -> nil
    end
  end

  def duration_ms(_track), do: nil

  @doc """
  Syncs `play_votes` for `play_id` to the room's current vote state, from
  an `updateChannelMeter` `voting` payload
  (`%{rvrb_id => %{"dope" => count, ...}}`). No-ops when `play_id` is
  `nil` - nothing playing that a vote could be attributed to.
  """
  def sync_votes(nil, _voting), do: :ok

  def sync_votes(play_id, voting) do
    voter_ids = User.get_ids(Map.keys(voting))
    PlayVote.sync(play_id, desired_votes(voting, voter_ids))
  end

  @doc """
  The set of `{voter_user_id, vote_type}` pairs a `voting` payload
  currently represents, given a `%{rvrb_id => internal_id}` map. Voters
  who aren't known users yet (no `updateChannelUsers` seen for them) are
  dropped rather than blocking the rest of the sync.
  """
  def desired_votes(voting, voter_ids) do
    for {rvrb_id, votes} <- voting,
        {vote_type, count} <- votes,
        vote_type in @vote_types,
        count > 0,
        voter_user_id = voter_ids[rvrb_id],
        voter_user_id != nil,
        into: MapSet.new() do
      {voter_user_id, vote_type}
    end
  end
end
