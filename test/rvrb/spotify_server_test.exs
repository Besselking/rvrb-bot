defmodule Rvrb.SpotifyServerTest do
  use ExUnit.Case, async: true

  alias Rvrb.SpotifyServer

  describe "page_artists/1" do
    test "collects the artists credited on each track" do
      page = %{
        "items" => [
          %{"track" => %{"artists" => [%{"id" => "a1", "name" => "One"}]}},
          %{
            "track" => %{
              "artists" => [%{"id" => "a2", "name" => "Two"}, %{"id" => "a3", "name" => "Three"}]
            }
          }
        ]
      }

      assert SpotifyServer.page_artists(page) == [
               %{"id" => "a1", "name" => "One"},
               %{"id" => "a2", "name" => "Two"},
               %{"id" => "a3", "name" => "Three"}
             ]
    end

    test "skips items that aren't a track with artists on them" do
      page = %{
        "items" => [
          # A track pulled from Spotify since it was added to the playlist.
          %{"track" => nil},
          # A podcast episode, which has no artists at all.
          %{"track" => %{"type" => "episode"}},
          %{"track" => %{"artists" => [%{"id" => "a1", "name" => "One"}]}}
        ]
      }

      assert SpotifyServer.page_artists(page) == [%{"id" => "a1", "name" => "One"}]
    end

    test "is empty for a page with no usable items" do
      assert SpotifyServer.page_artists(%{}) == []
      assert SpotifyServer.page_artists(%{"items" => nil}) == []
      assert SpotifyServer.page_artists(%{"items" => []}) == []
    end
  end
end
