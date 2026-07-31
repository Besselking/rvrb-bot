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
    belongs_to :play, Rvrb.Play
    belongs_to :voter, Rvrb.User, foreign_key: :voter_user_id
    field :vote_type, :string
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
  """
  def sync(play_id, desired) do
    existing =
      from(v in Rvrb.PlayVote,
        where: v.play_id == ^play_id,
        select: {v.voter_user_id, v.vote_type}
      )
      |> Rvrb.Repo.all()
      |> MapSet.new()

    for {voter_user_id, vote_type} <- MapSet.difference(desired, existing) do
      %Rvrb.PlayVote{}
      |> changeset(%{play_id: play_id, voter_user_id: voter_user_id, vote_type: vote_type})
      |> Rvrb.Repo.insert(on_conflict: :nothing)
    end

    for {voter_user_id, vote_type} <- MapSet.difference(existing, desired) do
      from(v in Rvrb.PlayVote,
        where:
          v.play_id == ^play_id and v.voter_user_id == ^voter_user_id and
            v.vote_type == ^vote_type
      )
      |> Rvrb.Repo.delete_all()
    end

    :ok
  end
end
