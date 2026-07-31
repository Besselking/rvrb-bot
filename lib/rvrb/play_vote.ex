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
end
