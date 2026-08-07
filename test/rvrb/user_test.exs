defmodule Rvrb.UserTest do
  use Rvrb.DataCase, async: true

  alias Rvrb.User

  # The shape RVRB sends in a `updateChannelUsers`-style payload.
  defp payload(id, attrs \\ %{}) do
    Map.merge(
      %{
        "_id" => id,
        "userName" => "user-#{id}",
        "displayName" => "User #{id}",
        "country" => "NL",
        "createdDate" => "2026-01-02T03:04:05.000Z"
      },
      attrs
    )
  end

  describe "update_users/1" do
    test "returns an empty list without touching the database for no users" do
      assert User.update_users([]) == []
    end

    test "inserts users it hasn't seen before" do
      assert [_, _] = users = User.update_users([payload("a"), payload("b")])

      assert Enum.map(users, & &1.rvrb_id) |> Enum.sort() == ["a", "b"]
      assert %User{user_name: "user-a", display_name: "User a", country: "NL"} = User.get("a")
      assert User.get("a").created_date == ~N[2026-01-02 03:04:05]
    end

    test "updates the mutable fields of a user it already has" do
      User.update_users([payload("a")])

      User.update_users([
        payload("a", %{"userName" => "renamed", "displayName" => "Renamed", "country" => "BE"})
      ])

      assert %User{user_name: "renamed", display_name: "Renamed", country: "BE"} = User.get("a")
      assert Repo.aggregate(from(u in User, where: u.rvrb_id == "a"), :count) == 1
    end

    test "keeps the fields the payload doesn't carry" do
      [user] = User.update_users([payload("a")])
      User.update_last_djed(user)
      User.update_received_skip(User.get("a"))

      User.update_users([payload("a", %{"displayName" => "New Name"})])

      assert %User{display_name: "New Name", received_skip: true, last_djed: last_djed} =
               User.get("a")

      assert last_djed != nil
    end

    test "returns only the users in the payload" do
      user_fixture(%{rvrb_id: "untouched"})

      assert [%User{rvrb_id: "a"}] = User.update_users([payload("a")])
    end

    test "handles a user with no display name or country" do
      assert [_] = User.update_users([payload("a", %{"displayName" => nil, "country" => nil})])
      assert %User{display_name: nil, country: nil} = User.get("a")
    end
  end

  describe "get/1 and get_by_user_name/1" do
    test "look a user up by each of their two identifiers" do
      user_fixture(%{rvrb_id: "abc", user_name: "dj_bes"})

      assert %User{user_name: "dj_bes"} = User.get("abc")
      assert %User{rvrb_id: "abc"} = User.get_by_user_name("dj_bes")
    end

    test "return nil for someone we've never seen" do
      assert User.get("nope") == nil
      assert User.get_by_user_name("nope") == nil
    end
  end

  describe "get_users/1" do
    test "maps rvrb_id to that user's fields" do
      user_fixture(%{rvrb_id: "a", user_name: "aaa", display_name: "AAA"})
      user_fixture(%{rvrb_id: "b", user_name: "bbb"})
      user_fixture(%{rvrb_id: "c"})

      users = User.get_users(["a", "b", "unknown"])

      assert Map.keys(users) |> Enum.sort() == ["a", "b"]
      assert %{rvrb_id: "a", user_name: "aaa", display_name: "AAA"} = users["a"]
      assert User.get_name(users, "a") == "AAA"
      assert User.get_name(users, "b") == "bbb"
      assert User.get_name(users, "unknown") == nil
    end

    test "is empty for no ids" do
      user_fixture()

      assert User.get_users([]) == %{}
    end
  end

  describe "get_ids/1" do
    test "maps rvrb_id to the internal id used as a foreign key" do
      one = user_fixture(%{rvrb_id: "a"})
      two = user_fixture(%{rvrb_id: "b"})

      assert User.get_ids(["a", "b", "unknown"]) == %{"a" => one.id, "b" => two.id}
    end
  end

  describe "update_last_djed/1 and update_received_skip/1" do
    test "stamp the user" do
      user = user_fixture()
      assert user.last_djed == nil

      assert {:ok, _} = User.update_last_djed(user)
      assert {:ok, _} = User.update_received_skip(User.get(user.rvrb_id))

      reloaded = User.get(user.rvrb_id)
      assert reloaded.last_djed != nil
      assert reloaded.received_skip == true
      assert User.get_last_djed(User.get_users([user.rvrb_id]), user.rvrb_id) != nil
      assert User.get_received_skip(User.get_users([user.rvrb_id]), user.rvrb_id) == true
    end

    test "do nothing for a user we don't have" do
      assert User.update_last_djed(nil) == nil
      assert User.update_received_skip(nil) == nil
    end
  end
end
