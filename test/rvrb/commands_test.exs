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
