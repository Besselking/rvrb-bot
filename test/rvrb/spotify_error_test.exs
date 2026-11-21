defmodule Rvrb.SpotifyErrorTest do
  use ExUnit.Case, async: true

  alias Rvrb.SpotifyError

  describe "message/1" do
    test "names the request and the reason" do
      message = Exception.message(%SpotifyError{reason: :closed, request: "artist 4Z8W4f"})

      assert message =~ "Spotify artist 4Z8W4f failed"
      assert message =~ ":closed"
    end

    test "points at the host's egress for a reason that never reached Spotify" do
      for reason <- [:closed, :timeout, :econnrefused, :nxdomain] do
        message = Exception.message(%SpotifyError{reason: reason, request: "artist x"})

        assert message =~ "can reach api.spotify.com",
               "expected an egress hint for #{inspect(reason)}"
      end
    end

    test "leaves an answer Spotify actually gave to speak for itself" do
      # What `unwrap!/2` hands over from a 4xx body: Spotify's own
      # `"error"` value, verified against a real request for an id it
      # doesn't have.
      body = %{"message" => "Resource not found", "status" => 404}
      message = Exception.message(%SpotifyError{reason: body, request: "artist 000"})

      assert message =~ "Resource not found"
      refute message =~ "can reach api.spotify.com"
    end
  end
end
