defmodule Rvrb.User do
  use Ecto.Schema

  import Ecto.Query

  schema "users" do
    field(:rvrb_id, :string)
    field(:user_name, :string)
    field(:display_name, :string)
    field(:country, :string)
    field(:created_date, :naive_datetime)
  end

  def changeset(person, params \\ %{}) do
    person
    |> Ecto.Changeset.cast(params, [
      :rvrb_id,
      :user_name,
      :display_name,
      :country,
      :created_date
    ])
    |> Ecto.Changeset.unique_constraint(:rvrb_id)
    |> Ecto.Changeset.validate_required([:rvrb_id, :user_name, :created_date])
  end

  def update_users([]), do: []
  def update_users(users) do
    repo_users = Enum.map(users, &%{
      rvrb_id: &1["_id"],
      user_name: &1["userName"],
      display_name:  Map.get(&1, "displayName"),
      country: Map.get(&1, "country"),
      created_date: &1["createdDate"]
        |> NaiveDateTime.from_iso8601!
        |> NaiveDateTime.truncate(:second)
    });

    upsert(repo_users)
  end

  defp upsert(users) do
    ids = Enum.map(users, &(&1.rvrb_id))

    Rvrb.Repo.insert_all(
      Rvrb.User,
      users,
      on_conflict: {:replace, [:display_name, :user_name, :country]},
      conflict_target: :rvrb_id
    )

    Rvrb.Repo.all(from t in Rvrb.User, where: t.rvrb_id in ^ids)
  end

  def get_names(ids) do
    query = Ecto.Query.from u in Rvrb.User,
      where: u.rvrb_id in ^ids,
      select: {u.rvrb_id, {u.display_name, u.user_name}}

      Rvrb.Repo.all(query)
      |> Enum.into(%{})
  end

  def get_name(_, nil), do: nil
  def get_name(map, id) do
    case map[id] do
      {"", user_name} -> user_name
      {nil, user_name} -> user_name
      {display_name, _} -> display_name
      nil -> id
    end
  end
end
