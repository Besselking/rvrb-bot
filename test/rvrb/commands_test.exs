defmodule Rvrb.CommandsTest do
  use ExUnit.Case, async: true

  alias Rvrb.Commands

  describe "parse/1" do
    test "returns :error for messages without the command prefix" do
      assert Commands.parse("hey everyone") == :error
      assert Commands.parse("") == :error
    end

    test "parses a bare command with no arguments" do
      assert Commands.parse("\\djs") == {:ok, "djs", ""}
    end

    test "parses a command with a single argument" do
      assert Commands.parse("\\qg rock") == {:ok, "qg", "rock"}
    end

    test "keeps the remainder of the message as one argument string" do
      assert Commands.parse("\\queue https://open.spotify.com/track/abc123") ==
               {:ok, "queue", "https://open.spotify.com/track/abc123"}
    end

    test "is case-insensitive on the command name" do
      assert Commands.parse("\\QG rock") == {:ok, "qg", "rock"}
    end

    test "trims surrounding whitespace" do
      assert Commands.parse("  \\djs  ") == {:ok, "djs", ""}
      assert Commands.parse("\\qg   rock  ") == {:ok, "qg", "rock"}
    end
  end

  describe "parse_tagged_username/1" do
    test "extracts the username from RVRB's rendered @-tag span" do
      assert Commands.parse_tagged_username(
               "<span class=\"username Bess\">@Bess 🐸 </span>"
             ) == "Bess"
    end

    test "does not mistake the display name (with emoji) for the username" do
      username =
        Commands.parse_tagged_username("<span class=\"username Bess\">@Bess 🐸 </span>")

      assert username == "Bess"
      refute username =~ "🐸"
    end

    test "falls back to a plain @username typed by hand" do
      assert Commands.parse_tagged_username("@Bess") == "Bess"
    end

    test "falls back to a bare username with no @ at all" do
      assert Commands.parse_tagged_username("Bess") == "Bess"
    end

    test "trims whitespace around a plain fallback username" do
      assert Commands.parse_tagged_username("  @Bess  ") == "Bess"
    end

    test "returns nil for blank args" do
      assert Commands.parse_tagged_username("") == nil
      assert Commands.parse_tagged_username("   ") == nil
      assert Commands.parse_tagged_username("@") == nil
    end
  end

  describe "stats_table/2" do
    setup do
      user = %Rvrb.User{
        user_name: "Bess",
        display_name: "Bess 🐸",
        created_date: ~N[2024-01-01 00:00:00],
        last_djed: ~N[2024-06-01 00:00:00],
        received_skip: true
      }

      empty_stats = %{
        play_count: 0,
        dopes_received: 0,
        stars_received: 0,
        most_played: nil,
        best_play: nil,
        most_played_artist: nil,
        best_artist: nil,
        favorite_dj: nil,
        favorite_track: nil,
        favorite_artist: nil
      }

      %{user: user, empty_stats: empty_stats}
    end

    test "groups the rows under section headers", %{user: user, empty_stats: stats} do
      html = Commands.stats_table(user, stats)

      assert html =~ "<tr><th>Profile</th>"
      assert html =~ "<tr><th><span class=\"alert\">Behind the decks</span></th>"
      assert html =~ "<tr><th><span class=\"alert\">In the crowd</span></th>"
    end

    test "titles the table with the user's display name", %{user: user, empty_stats: stats} do
      assert Commands.stats_table(user, stats) =~ "<th>Bess 🐸's stats</th>"
    end

    test "calls stars favorites, never stars", %{user: user, empty_stats: stats} do
      stats = %{
        stats
        | stars_received: 7,
          best_play: %{
            track_name: "Alpha",
            artist_names: ["Nova"],
            score: 5,
            dopes: 1,
            stars: 1
          }
      }

      html = Commands.stats_table(user, stats)

      assert html =~ "<td>Favorites received</td><td>7</td>"
      assert html =~ "1 favorite)"
      refute html =~ "star"
    end

    test "renders the three favorite stats", %{user: user, empty_stats: stats} do
      stats = %{
        stats
        | favorite_dj: %{
            display_name: nil,
            user_name: "DjA",
            score: 8,
            dopes: 0,
            stars: 2
          },
          favorite_track: %{
            track_name: "Alpha",
            artist_names: ["Nova", "Orion"],
            score: 8,
            dopes: 0,
            stars: 2
          },
          favorite_artist: %{artist_name: "Nova", score: 9}
      }

      html = Commands.stats_table(user, stats)

      assert html =~ "<td>Favorite DJ</td><td>DjA — 8 pts (0 dopes, 2 favorites)</td>"

      assert html =~
               "<td>Favorite track</td><td>Alpha — Nova, Orion — 8 pts (0 dopes, 2 favorites)</td>"

      assert html =~ "<td>Favorite artist</td><td>Nova — 9 pts</td>"
    end

    test "falls back to a dash for favorites the user has none of", %{
      user: user,
      empty_stats: stats
    } do
      html = Commands.stats_table(user, stats)

      assert html =~ "<td>Favorite DJ</td><td>—</td>"
      assert html =~ "<td>Favorite track</td><td>—</td>"
      assert html =~ "<td>Favorite artist</td><td>—</td>"
    end
  end

  describe "commands/0" do
    test "includes a help command" do
      assert Enum.any?(Commands.commands(), &(&1.name == "help"))
    end

    test "every command has a usage and description" do
      for command <- Commands.commands() do
        assert is_binary(command.usage) and command.usage != ""
        assert is_binary(command.description) and command.description != ""
        assert is_function(command.handler, 3)
      end
    end
  end
end
