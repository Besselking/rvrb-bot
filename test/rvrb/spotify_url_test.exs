defmodule Rvrb.SpotifyUrlTest do
  @moduledoc """
  `\\queue` hands this whatever the room typed, so every branch here is
  reachable from chat. `Rvrb.Commands` destructures the result as
  `{type, id}`, so an `{:error, _}` from a link we can't read raises a
  MatchError inside `Commands.run/5` - contained, but it costs the command,
  which is why the rejection paths are worth pinning too.
  """
  use ExUnit.Case, async: true

  alias Rvrb.SpotifyUrl

  describe "parse/1 on a plain url" do
    test "reads a track link" do
      assert SpotifyUrl.parse("https://open.spotify.com/track/1HSVmNmRkrAyKahBe6Szx2") ==
               {:track, "1HSVmNmRkrAyKahBe6Szx2"}
    end

    test "reads an album link" do
      assert SpotifyUrl.parse("https://open.spotify.com/album/4e5dxIGtajnaLdMDSqxTrD") ==
               {:album, "4e5dxIGtajnaLdMDSqxTrD"}
    end

    # RVRB's own share links carry one, so this is the common case rather
    # than the edge one.
    test "keeps the ?si= tracking parameter out of the id" do
      assert SpotifyUrl.parse(
               "https://open.spotify.com/track/1HSVmNmRkrAyKahBe6Szx2?si=bc4ae348e57842ec"
             ) == {:track, "1HSVmNmRkrAyKahBe6Szx2"}
    end

    test "rejects a spotify path we don't handle" do
      assert {:error, message} =
               SpotifyUrl.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")

      assert message =~ "unexpected spotify path"
    end

    test "rejects a host that isn't spotify" do
      assert {:error, message} = SpotifyUrl.parse("https://youtube.com/watch?v=abc")
      assert message =~ "unexpected authority"
    end

    test "rejects text that isn't a url at all" do
      assert {:error, _} = SpotifyUrl.parse("just some words")
      assert {:error, _} = SpotifyUrl.parse("")
    end
  end

  describe "parse/1 on a pasted link" do
    test "reads the href out of an anchor tag" do
      html =
        ~s(<a href="https://open.spotify.com/album/4e5dxIGtajnaLdMDSqxTrD?si=35e63279bf2a4c4c" target="_blank"/>https://open.spotify.com/album/4e5dxIGtajnaLdMDSqxTrD</a>)

      assert SpotifyUrl.parse(html) == {:album, "4e5dxIGtajnaLdMDSqxTrD"}
    end

    test "rejects an anchor with no href" do
      assert {:error, message} = SpotifyUrl.parse(~s(<a target="_blank">click me</a>))
      assert message =~ "invalid Url"
    end
  end

  describe "parse_path/1" do
    test "splits the type off the id" do
      assert SpotifyUrl.parse_path("/track/abc") == {:track, "abc"}
      assert SpotifyUrl.parse_path("/album/abc") == {:album, "abc"}
      assert {:error, _} = SpotifyUrl.parse_path("/artist/abc")
    end
  end
end
