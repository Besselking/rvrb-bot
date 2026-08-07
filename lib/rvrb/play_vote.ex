defmodule Rvrb.PlayVote do
  @moduledoc """
  Records who cast a dope/star (and, in principle, boofstar/nope) on a
  given play. `updateChannelMeter` reports the room's *current* vote
  tallies on every update, not a delta, so this table has to be kept in
  sync as current state rather than appended to as a log: a vote is
  inserted the first time a listener casts it and deleted if they take it
  back, upserted idempotently via the unique index on
  `(play_id, voter_user_id, vote_type)`.

  Storing individual voters instead of a plain count on `Rvrb.Play` costs
  a bit more upkeep but is strictly more useful: a count can always be
  derived from these rows (`count(*) group by play_id, vote_type`), but
  the reverse isn't true - once collapsed into a number, who voted is
  gone for good. That's what makes stats like "who dopes your tracks the
  most" possible later.
  """
  use Ecto.Schema

  import Ecto.Query

  schema "play_votes" do
    belongs_to(:play, Rvrb.Play)
    belongs_to(:voter, Rvrb.User, foreign_key: :voter_user_id)
    field(:vote_type, :string)
  end

  def changeset(vote, params \\ %{}) do
    vote
    |> Ecto.Changeset.cast(params, [:play_id, :voter_user_id, :vote_type])
    |> Ecto.Changeset.validate_required([:play_id, :voter_user_id, :vote_type])
    |> Ecto.Changeset.validate_inclusion(:vote_type, ~w[dope star boofstar nope])
    |> Ecto.Changeset.foreign_key_constraint(:play_id)
    |> Ecto.Changeset.foreign_key_constraint(:voter_user_id)
    |> Ecto.Changeset.unique_constraint([:play_id, :voter_user_id, :vote_type])
  end

  @doc """
  Syncs the votes recorded for `play_id` to exactly `desired` - a
  `MapSet` of `{voter_user_id, vote_type}` tuples representing the room's
  current vote state. Inserts whatever's missing, deletes whatever's no
  longer there.

  Both halves go out as a single statement each (`insert_all` /
  `delete_all`) rather than a round-trip per vote: this runs on every
  `updateChannelMeter`, so a room where a dozen people vote on a track
  would otherwise pay a dozen round-trips for what Postgres can do in one.
  """
  def sync(play_id, desired) do
    existing =
      from(v in Rvrb.PlayVote,
        where: v.play_id == ^play_id,
        select: {v.voter_user_id, v.vote_type}
      )
      |> Rvrb.Repo.all()
      |> MapSet.new()

    missing = MapSet.difference(desired, existing)
    stale = MapSet.difference(existing, desired)

    # The common case by far is a meter that changed nothing we track, so
    # neither statement is worth a round-trip unless it has rows to touch.
    if MapSet.size(missing) > 0, do: insert_missing(play_id, missing)
    if MapSet.size(stale) > 0, do: delete_stale(play_id, stale)

    :ok
  end

  defp insert_missing(play_id, missing) do
    entries =
      for {voter_user_id, vote_type} <- missing do
        %{play_id: play_id, voter_user_id: voter_user_id, vote_type: vote_type}
      end

    Rvrb.Repo.insert_all(Rvrb.PlayVote, entries,
      on_conflict: :nothing,
      conflict_target: [:play_id, :voter_user_id, :vote_type]
    )
  end

  defp delete_stale(play_id, stale) do
    # One OR'd condition per withdrawn vote. `{voter, type} IN ((?, ?), ...)`
    # would be tidier SQL, but Ecto has no row-constructor support, and the
    # set is only ever as big as the number of votes that changed since the
    # last meter.
    matches =
      Enum.reduce(stale, dynamic(false), fn {voter_user_id, vote_type}, acc ->
        dynamic(
          [v],
          ^acc or (v.voter_user_id == ^voter_user_id and v.vote_type == ^vote_type)
        )
      end)

    from(v in Rvrb.PlayVote, where: ^dynamic([v], v.play_id == ^play_id and ^matches))
    |> Rvrb.Repo.delete_all()
  end
end
