defmodule Rvrb.Fixtures do
  @moduledoc """
  Row builders for the DB-backed tests. Every field the queries under test
  actually read can be overridden; the rest just needs to be present and
  unique enough to satisfy the schema, so it's filled in here.
  """

  @doc """
  A `Rvrb.User`. `rvrb_id` and `user_name` default to unique values, so a
  test that doesn't care about identity can call this repeatedly.
  """
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    %Rvrb.User{}
    |> Rvrb.User.changeset(
      Map.merge(
        %{
          rvrb_id: "rvrb-#{n}",
          user_name: "user#{n}",
          created_date: now()
        },
        Map.new(attrs)
      )
    )
    |> Rvrb.Repo.insert!()
  end

  @doc """
  A `Rvrb.Play` by `user`. Accepts either a `Rvrb.User` or a raw internal
  user id, so it composes with `user_fixture/1` without unwrapping.
  """
  def play_fixture(user, attrs \\ %{})

  def play_fixture(%Rvrb.User{id: user_id}, attrs), do: play_fixture(user_id, attrs)

  def play_fixture(user_id, attrs) when is_integer(user_id) do
    n = System.unique_integer([:positive])

    %Rvrb.Play{}
    |> Rvrb.Play.changeset(
      Map.merge(
        %{
          user_id: user_id,
          spotify_track_id: "track-#{n}",
          track_name: "Track #{n}",
          artist_names: ["Artist #{n}"],
          played_at: now()
        },
        Map.new(attrs)
      )
    )
    |> Rvrb.Repo.insert!()
  end

  @doc "A vote of `vote_type` cast on `play` by `voter`."
  def vote_fixture(play, voter, vote_type \\ "dope")

  def vote_fixture(%Rvrb.Play{id: play_id}, voter, vote_type),
    do: vote_fixture(play_id, voter, vote_type)

  def vote_fixture(play_id, %Rvrb.User{id: voter_id}, vote_type),
    do: vote_fixture(play_id, voter_id, vote_type)

  def vote_fixture(play_id, voter_id, vote_type)
      when is_integer(play_id) and is_integer(voter_id) do
    %Rvrb.PlayVote{}
    |> Rvrb.PlayVote.changeset(%{
      play_id: play_id,
      voter_user_id: voter_id,
      vote_type: vote_type
    })
    |> Rvrb.Repo.insert!()
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
