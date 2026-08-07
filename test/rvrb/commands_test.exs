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
      assert Commands.parse_tagged_username("<span class=\"username Bess\">@Bess 🐸 </span>") ==
               "Bess"
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

  describe "parse_editbot/1" do
    test "maps a chat field name onto its editUser param" do
      assert Commands.parse_editbot("displayname BotName") == {:ok, :displayName, "BotName"}
      assert Commands.parse_editbot("bio This is a bot") == {:ok, :bio, "This is a bot"}

      assert Commands.parse_editbot("djimage /static/dj.webp") ==
               {:ok, :djImage, "/static/dj.webp"}

      assert Commands.parse_editbot("thumbsup /static/up.webp") ==
               {:ok, :thumbsUpImage, "/static/up.webp"}

      assert Commands.parse_editbot("thumbsdown /static/down.png") ==
               {:ok, :thumbsDownImage, "/static/down.png"}
    end

    test "is case-insensitive on the field name" do
      assert Commands.parse_editbot("DisplayName BotName") == {:ok, :displayName, "BotName"}
    end

    test "keeps spaces in the value, since names and bios have them" do
      assert Commands.parse_editbot("displayname  Bot  The  Bot ") ==
               {:ok, :displayName, "Bot  The  Bot"}
    end

    test "lists the known fields when given no arguments" do
      assert {:error, message} = Commands.parse_editbot("")
      assert message =~ "displayname"
      assert message =~ "thumbsdown"
    end

    test "rejects a field the bot doesn't have" do
      assert {:error, message} = Commands.parse_editbot("nickname BotName")
      assert message =~ "no nickname"
    end

    test "rejects a known field with no value" do
      assert {:error, message} = Commands.parse_editbot("bio")
      assert message =~ "needs a value"
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

      # The labels are what matter, not how they're styled - assert they land
      # in a header row (<th>) rather than a data row, ignoring inline markup.
      assert "Profile" in header_labels(html)
      assert "Behind the decks" in header_labels(html)
      assert "In the crowd" in header_labels(html)
    end

    test "titles the table with the user's display name", %{user: user, empty_stats: stats} do
      assert Commands.stats_table(user, stats) =~ "<th>Bess 🐸&#39;s stats</th>"
    end

    test "escapes markup in names it doesn't control", %{user: user, empty_stats: stats} do
      user = %{user | display_name: "<img src=x onerror=alert(1)>"}

      stats = %{
        stats
        | most_played: %{
            track_name: "<b>Alpha</b>",
            artist_names: ["Nova & Co"],
            play_count: 3
          }
      }

      html = Commands.stats_table(user, stats)

      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
      assert html =~ "<td>&lt;b&gt;Alpha&lt;/b&gt; — Nova &amp; Co (3×)</td>"
      refute html =~ "<img"
      # The section headers still get to be markup.
      assert html =~ "<span class=\"alert\">Behind the decks</span>"
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

  describe "rotation_table/3" do
    @minute 60_000

    setup do
      estimate =
        Rvrb.Rotation.estimate(
          ["dj-a", "dj-b"],
          %{"dj-a" => %{avg_ms: 3 * @minute, play_count: 4}},
          remaining_ms: @minute,
          fallback_ms: 5 * @minute
        )

      dj_map = %{
        "dj-a" => %{display_name: "Ada", user_name: "ada"},
        "dj-b" => %{display_name: nil, user_name: "bo"}
      }

      %{estimate: estimate, dj_map: dj_map}
    end

    test "titles the table with one lap of the queue", %{estimate: estimate, dj_map: dj_map} do
      assert Commands.rotation_table(estimate, dj_map, "dj-b") =~
               "<th>DJ rotation - one lap ≈ 8m 0s</th>"
    end

    test "marks the DJ currently playing", %{estimate: estimate, dj_map: dj_map} do
      assert Commands.rotation_table(estimate, dj_map, "dj-b") =~ "<td>▶ Ada</td>"
      assert Commands.rotation_table(estimate, dj_map, "dj-b") =~ "<td>bo</td>"
    end

    test "shows how many plays each average is drawn from", %{
      estimate: estimate,
      dj_map: dj_map
    } do
      html = Commands.rotation_table(estimate, dj_map, "dj-b")

      assert html =~ "<td>3m 0s (over 4 plays)</td>"
      assert html =~ "<td>5m 0s (guess)</td>"
    end

    test "counts down to each DJ's next play", %{estimate: estimate, dj_map: dj_map} do
      html = Commands.rotation_table(estimate, dj_map, "dj-b")

      # Ada is playing, so she's up again after the rest of the queue
      assert html =~ "<td>≈ 6m 0s</td>"
      # bo is next, as soon as the current track's last minute is up
      assert html =~ "<td>≈ 1m 0s</td>"
    end

    test "tells a queued DJ when they're up", %{estimate: estimate, dj_map: dj_map} do
      assert Commands.rotation_table(estimate, dj_map, "dj-b") =~ "You're up in ≈ 1m 0s."
    end

    test "tells the DJ playing right now when they're back up", %{
      estimate: estimate,
      dj_map: dj_map
    } do
      assert Commands.rotation_table(estimate, dj_map, "dj-a") =~
               "You're playing right now - you're back up in ≈ 6m 0s."
    end

    test "tells a listener they're not in the queue", %{estimate: estimate, dj_map: dj_map} do
      html = Commands.rotation_table(estimate, dj_map, "listener")

      assert html =~ "You're not in the DJ queue"
      refute html =~ "You're up in"
    end

    test "falls back to a placeholder for a DJ we have no user record for", %{estimate: estimate} do
      assert Commands.rotation_table(estimate, %{}, "listener") =~ "<td>someone</td>"
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

  # The text of every header cell that opens a row, with any inline markup
  # (styling spans and the like) stripped out.
  defp header_labels(html) do
    ~r{<tr><th>(.*?)</th>}
    |> Regex.scan(html)
    |> Enum.map(fn [_match, label] -> String.replace(label, ~r{<[^>]*>}, "") end)
  end
end
