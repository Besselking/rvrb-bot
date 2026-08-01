defmodule Rvrb.User do
  use Ecto.Schema

  import Ecto.Query

  schema "users" do
    field(:rvrb_id, :string)
    field(:user_name, :string)
    field(:display_name, :string)
    field(:country, :string)
    field(:created_date, :naive_datetime)
    field(:last_djed, :naive_datetime)
    field(:received_skip, :boolean)
    has_many(:plays, Rvrb.Play)
    has_many(:cast_votes, Rvrb.PlayVote, foreign_key: :voter_user_id)
  end

  def changeset(person, params \\ %{}) do
    person
    |> Ecto.Changeset.cast(params, [
      :rvrb_id,
      :user_name,
      :display_name,
      :country,
      :created_date,
      :last_djed,
      :received_skip
    ])
    |> Ecto.Changeset.unique_constraint(:rvrb_id)
    |> Ecto.Changeset.validate_required([:rvrb_id, :user_name, :created_date])
  end

  def get(id) do
    Rvrb.Repo.get_by(Rvrb.User, rvrb_id: id)
  end

  @doc "Looks a user up by their RVRB username (as opposed to their internal rvrb_id)."
  def get_by_user_name(user_name) do
    Rvrb.Repo.get_by(Rvrb.User, user_name: user_name)
  end

  def update_last_djed(nil), do: nil

  def update_last_djed(user) do
    update_dj_timestamp =
      changeset(user, %{
        last_djed: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      })

    Rvrb.Repo.update(update_dj_timestamp)
  end

  def update_received_skip(nil), do: nil

  def update_received_skip(user) do
    update_user_received_skip =
      changeset(user, %{
        received_skip: true
      })

    Rvrb.Repo.update(update_user_received_skip)
  end

  def update_users([]), do: []

  def update_users(users) do
    repo_users =
      Enum.map(
        users,
        &%{
          rvrb_id: &1["_id"],
          user_name: &1["userName"],
          display_name: Map.get(&1, "displayName"),
          country: Map.get(&1, "country"),
          created_date:
            &1["createdDate"]
            |> NaiveDateTime.from_iso8601!()
            |> NaiveDateTime.truncate(:second)
        }
      )

    upsert(repo_users)
  end

  defp upsert(users) do
    ids = Enum.map(users, & &1.rvrb_id)

    Rvrb.Repo.insert_all(
      Rvrb.User,
      users,
      on_conflict: {:replace, [:display_name, :user_name, :country]},
      conflict_target: :rvrb_id
    )

    Rvrb.Repo.all(from(t in Rvrb.User, where: t.rvrb_id in ^ids))
  end

  @doc "Maps rvrb_id => a lookup map of that user's fields, for the given rvrb_ids."
  def get_users(ids) do
    query =
      Ecto.Query.from(u in Rvrb.User,
        where: u.rvrb_id in ^ids,
        select: %{
          rvrb_id: u.rvrb_id,
          display_name: u.display_name,
          user_name: u.user_name,
          last_djed: u.last_djed,
          created_date: u.created_date,
          received_skip: u.received_skip
        }
      )

    query
    |> Rvrb.Repo.all()
    |> Map.new(&{&1.rvrb_id, &1})
  end

  @doc "Maps rvrb_id => internal id for the given rvrb_ids, for use as a foreign key elsewhere."
  def get_ids(rvrb_ids) do
    query = Ecto.Query.from(u in Rvrb.User, where: u.rvrb_id in ^rvrb_ids, select: {u.rvrb_id, u.id})

    Rvrb.Repo.all(query)
    |> Enum.into(%{})
  end

  def get_name(_, nil), do: nil

  def get_name(map, id) do
    case map[id] do
      nil ->
        nil

      %{display_name: display_name, user_name: user_name} when display_name in [nil, ""] ->
        user_name

      %{display_name: display_name} ->
        display_name
    end
  end

  def get_last_djed(_, nil), do: nil

  def get_last_djed(map, id) do
    case map[id] do
      nil -> nil
      %{last_djed: last_djed} -> last_djed
    end
  end

  def get_received_skip(_, nil), do: nil

  def get_received_skip(map, id) do
    case map[id] do
      nil -> nil
      %{received_skip: received_skip} -> received_skip
    end
  end

  def get_created_date(_, nil), do: nil

  def get_created_date(map, id) do
    case map[id] do
      nil -> nil
      %{created_date: created_date} -> created_date
    end
  end
end
