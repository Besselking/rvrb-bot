defmodule Rvrb.ApiTest do
  use ExUnit.Case, async: true

  alias Rvrb.Api

  # The requests themselves need RVRB to answer; what can be pinned down
  # without it is that a call missing its ids says so in chat terms instead
  # of sending a request to a nonsense url.
  test "put_djs/2 refuses before the bot has joined a channel" do
    assert {:error, message} = Api.put_djs(nil, ["dj-a"])
    assert message =~ "not joined a channel"
  end

  test "patch_user/2 refuses before the bot knows its own id" do
    assert {:error, message} = Api.patch_user(nil, %{bio: "hi"})
    assert message =~ "own user id"
  end
end
