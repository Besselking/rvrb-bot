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
  end

  def changeset(person, params \\ %{}) do
    person
    |> Ecto.Changeset.cast(params, [
      :rvrb_id,
      :user_name,
      :display_name,
      :country,
      :created_date,
      :last_djed
    ])
    |> Ecto.Changeset.unique_constraint(:rvrb_id)
    |> Ecto.Changeset.validate_required([:rvrb_id, :user_name, :created_date])
  end

  def get(id) do
    Rvrb.Repo.get_by(Rvrb.User, rvrb_id: id)
  end

  def update_last_djed(user) do
    if user == nil do
      nil
    end
    update_dj_timestamp = changeset(user, %{
      last_djed: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    })
    Rvrb.Repo.update(update_dj_timestamp)
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

  def get_users(ids) do
    query = Ecto.Query.from u in Rvrb.User,
      where: u.rvrb_id in ^ids,
      select: {u.rvrb_id, {u.display_name, u.user_name, u.last_djed, u.created_date}}

      Rvrb.Repo.all(query)
      |> Enum.into(%{})
  end

  def get_name(_, nil), do: nil
  def get_name(map, id) do
    case map[id] do
      {"", user_name, _, _} -> user_name
      {nil, user_name, _, _} -> user_name
      {display_name, _, _, _} -> display_name
      nil -> id
    end
  end

  def get_last_djed(_, nil), do: nil
  def get_last_djed(map, id) do
    case map[id] do
      {_, _, last_djed, _} -> last_djed
      nil -> id
    end
  end

  def get_created_date(_, nil), do: nil
  def get_created_date(map, id) do
    case map[id] do
      {_, _, _, created_date} -> created_date
      nil -> id
    end
  end
end
