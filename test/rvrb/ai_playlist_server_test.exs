defmodule Rvrb.AiPlaylistServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Rvrb.AiPlaylistServer

  @slop "1VX1plT2A6rwob0SwuEkvH"
  @suno "7pRdrM4ZyQFStXGGowzRGk"

  # Stands in for `Rvrb.SpotifyServer`. Reads the playlists a test set up
  # and reports every call back to it, so a test can assert on which
  # requests the refresh actually made.
  defmodule StubSpotify do
    def playlist_artists(playlist_id) do
      %{owner: owner, playlists: playlists} = config()
      send(owner, {:playlist_artists, playlist_id})

      {get_in(playlists, [playlist_id, :status]) || :ok,
       get_in(playlists, [playlist_id, :artists]) || []}
    end

    def playlist_name(playlist_id) do
      %{owner: owner, playlists: playlists} = config()
      send(owner, {:playlist_name, playlist_id})
      get_in(playlists, [playlist_id, :name])
    end

    defp config, do: Application.fetch_env!(:rvrb, __MODULE__)
  end

  setup do
    on_exit(fn -> Application.delete_env(:rvrb, StubSpotify) end)
    :ok
  end

  describe "index/1" do
    test "maps every artist on a playlist to it" do
      index =
        AiPlaylistServer.index([
          %{id: @slop, name: "Probably AI Clanker SLOP", artist_ids: ["a1", "a2"]}
        ])

      assert index == %{
               "a1" => [%{id: @slop, name: "Probably AI Clanker SLOP"}],
               "a2" => [%{id: @slop, name: "Probably AI Clanker SLOP"}]
             }
    end

    test "an artist on two lists keeps both, in the order the playlists came in" do
      index =
        AiPlaylistServer.index([
          %{id: @slop, name: "Probably AI Clanker SLOP", artist_ids: ["a1"]},
          %{id: @suno, name: "Suno Generated Music", artist_ids: ["a1", "a2"]}
        ])

      assert index["a1"] == [
               %{id: @slop, name: "Probably AI Clanker SLOP"},
               %{id: @suno, name: "Suno Generated Music"}
             ]

      assert index["a2"] == [%{id: @suno, name: "Suno Generated Music"}]
    end

    test "an artist with several tracks on one list is only credited to it once" do
      index = AiPlaylistServer.index([%{id: @slop, name: "SLOP", artist_ids: ["a1", "a1", "a1"]}])

      assert index["a1"] == [%{id: @slop, name: "SLOP"}]
    end

    test "is empty for no playlists" do
      assert AiPlaylistServer.index([]) == %{}
    end
  end

  describe "lookup_in/2" do
    @index %{"a1" => [%{id: @slop, name: "SLOP"}]}

    test "returns the playlists an indexed artist is on" do
      assert AiPlaylistServer.lookup_in(@index, "a1") == {:listed, [%{id: @slop, name: "SLOP"}]}
    end

    test "returns :none for an artist who isn't on any of them" do
      assert AiPlaylistServer.lookup_in(@index, "nobody") == :none
    end
  end

  describe "lookup/2" do
    test "answers :unknown rather than exiting when the server isn't running" do
      assert AiPlaylistServer.lookup(:no_such_ai_playlist_server, "a1") == :unknown
    end

    test "answers :unknown for anything that isn't an artist id" do
      assert AiPlaylistServer.lookup(nil) == :unknown
    end

    test "reports listed and unlisted artists once the first fetch has landed" do
      server =
        start_stub(%{
          @slop => %{name: "Probably AI Clanker SLOP", artists: [artist("a1"), artist("a2")]}
        })

      await_refresh(server)

      assert AiPlaylistServer.lookup(server, "a1") ==
               {:listed, [%{id: @slop, name: "Probably AI Clanker SLOP"}]}

      assert AiPlaylistServer.lookup(server, "real-artist") == :none
    end

    test "answers :unknown until the first fetch has landed" do
      # Nothing to index, so the server never reaches a loaded state - and
      # "we have no list" must not be reported as "they're not on it".
      log =
        capture_log(fn ->
          server = start_stub(%{@slop => %{name: "SLOP", artists: []}})
          await_refresh(server)

          assert AiPlaylistServer.lookup(server, "a1") == :unknown
        end)

      assert log =~ "came back empty"
    end
  end

  describe "refreshing" do
    test "skips the name request for a playlist whose tracks didn't come back" do
      # One list failing also makes the refresh a partial one, hence the
      # captured warning.
      capture_log(fn ->
        server =
          start_stub(%{
            @slop => %{name: "SLOP", artists: []},
            @suno => %{name: "Suno Generated Music", artists: [artist("a1")]}
          })

        await_refresh(server)
      end)

      assert_received {:playlist_artists, @slop}
      refute_received {:playlist_name, @slop}
      assert_received {:playlist_name, @suno}
    end

    test "a refresh that comes back empty keeps the index it already had" do
      server = start_stub(%{@slop => %{name: "SLOP", artists: [artist("a1")]}})
      await_refresh(server)
      assert {:listed, _playlists} = AiPlaylistServer.lookup(server, "a1")

      # Spotify goes away, and the daily refresh returns nothing. A day-old
      # answer beats no answer at all.
      capture_log(fn ->
        put_playlists(%{@slop => %{name: "SLOP", artists: []}})
        send(server, :refresh)
        await_refresh(server)
      end)

      assert {:listed, _playlists} = AiPlaylistServer.lookup(server, "a1")
    end

    test "a crashing refresh costs a retry rather than the server" do
      log =
        capture_log(fn ->
          server = start_stub(:boom)
          await_refresh(server)

          assert Process.alive?(server)
          assert AiPlaylistServer.lookup(server, "a1") == :unknown
        end)

      assert log =~ "refresh failed"
    end
  end

  describe "a partially fetched refresh" do
    test "is adopted when there's no index yet, since some of the list beats none" do
      log =
        capture_log(fn ->
          server =
            start_stub(%{
              @slop => %{name: "SLOP", artists: [artist("a1")], status: :partial},
              @suno => %{name: "Suno Generated Music", artists: [artist("a2")]}
            })

          await_refresh(server)

          assert {:listed, _playlists} = AiPlaylistServer.lookup(server, "a1")
          # It counts as a failure, so the next try comes round sooner than
          # the daily refresh would.
          assert :sys.get_state(server).failures == 1
        end)

      assert log =~ "incomplete"
    end

    test "doesn't replace an index it already has with a shorter one" do
      server =
        start_stub(%{
          @slop => %{name: "SLOP", artists: [artist("a1"), artist("a2")]},
          @suno => %{name: "Suno Generated Music", artists: [artist("a3")]}
        })

      await_refresh(server)
      assert {:listed, _playlists} = AiPlaylistServer.lookup(server, "a2")

      # Spotify throttles the next day's refresh halfway through it.
      capture_log(fn ->
        put_playlists(%{
          @slop => %{name: "SLOP", artists: [artist("a1")], status: :partial},
          @suno => %{name: "Suno Generated Music", artists: []}
        })

        send(server, :refresh)
        await_refresh(server)
      end)

      assert {:listed, _playlists} = AiPlaylistServer.lookup(server, "a2")
    end

    test "a playlist that came back empty makes the whole refresh partial" do
      log =
        capture_log(fn ->
          server =
            start_stub(%{
              @slop => %{name: "SLOP", artists: [artist("a1")]},
              @suno => %{name: "Suno Generated Music", artists: []}
            })

          await_refresh(server)

          assert {:listed, _playlists} = AiPlaylistServer.lookup(server, "a1")
          assert :sys.get_state(server).failures == 1
        end)

      assert log =~ "incomplete"
    end

    test "a refresh with every page intact is not treated as a failure" do
      server = start_stub(%{@slop => %{name: "SLOP", artists: [artist("a1")]}})
      await_refresh(server)

      assert :sys.get_state(server).failures == 0
    end
  end

  describe "retry_interval/1" do
    test "starts at half an hour and doubles per consecutive failure" do
      assert AiPlaylistServer.retry_interval(1) == :timer.minutes(30)
      assert AiPlaylistServer.retry_interval(2) == :timer.hours(1)
      assert AiPlaylistServer.retry_interval(3) == :timer.hours(2)
    end

    test "never backs off past the ordinary refresh interval" do
      assert AiPlaylistServer.retry_interval(7) == :timer.hours(24)
      assert AiPlaylistServer.retry_interval(1_000) == :timer.hours(24)
    end
  end

  defp artist(id), do: %{"id" => id, "name" => "Artist #{id}"}

  defp start_stub(playlists) do
    put_playlists(playlists)

    start_supervised!(
      {AiPlaylistServer,
       playlist_ids: playlist_ids(playlists), spotify: StubSpotify, name: :ai_playlists_test}
    )
  end

  # `:boom` has no playlists to look up, so the stub raises on the first
  # fetch - which is what a deployment with no Spotify credentials does.
  defp playlist_ids(:boom), do: [@slop]
  defp playlist_ids(playlists), do: Map.keys(playlists)

  defp put_playlists(:boom), do: Application.delete_env(:rvrb, StubSpotify)

  defp put_playlists(playlists) do
    Application.put_env(:rvrb, StubSpotify, %{owner: self(), playlists: playlists})
  end

  # The refresh runs in a process of its own, so it's finished when the
  # server has stopped tracking one. `handle_continue/2` runs before this
  # first `:sys.get_state/1` is answered, so there's no window where a
  # refresh that hasn't started yet reads as one that's already done.
  defp await_refresh(server) do
    Enum.reduce_while(1..200, nil, fn _attempt, _acc ->
      if :sys.get_state(server).refreshing do
        Process.sleep(5)
        {:cont, nil}
      else
        {:halt, :ok}
      end
    end)
    |> case do
      :ok -> :ok
      _timeout -> flunk("the refresh never finished")
    end

    # Logger hands off asynchronously, so whatever the refresh logged on its
    # way out has to be flushed before a `capture_log/1` around this call
    # can see it - or fail to suppress it.
    Logger.flush()
  end
end
