defmodule Rvrb.GenreServerTest do
  use ExUnit.Case, async: true

  alias Rvrb.GenreServer

  # The application doesn't start this one in test (see
  # `Rvrb.Application.start/2`), so the tests that call the running server
  # start their own.
  setup do
    start_supervised!({GenreServer, Application.app_dir(:rvrb, "priv/genres.txt")})
    :ok
  end

  describe "matching/2" do
    @genres ["pop", "post-rock", "Detroit Techno", "hard rock"]

    test "finds genres containing the keyword" do
      assert GenreServer.matching(@genres, "rock") == ["post-rock", "hard rock"]
    end

    test "ignores case on both sides" do
      assert GenreServer.matching(@genres, "ROCK") == ["post-rock", "hard rock"]
      assert GenreServer.matching(@genres, "techno") == ["Detroit Techno"]
    end

    test "returns an empty list when nothing matches" do
      assert GenreServer.matching(@genres, "zzzz") == []
    end
  end

  describe "get_genre/1" do
    test "returns nil instead of crashing when no genre matches" do
      assert GenreServer.get_genre("zzzzzzzzzz") == nil
      # The server survived answering, so the caller's connection does too.
      assert Process.alive?(Process.whereis(GenreServer))
    end

    test "matches a keyword regardless of case" do
      assert GenreServer.get_genre("Rock") =~ "rock"
    end
  end

  describe "get_genre/0" do
    test "returns a genre from the list" do
      assert is_binary(GenreServer.get_genre())
    end
  end
end
