defmodule Rvrb.GenreServer do
  use GenServer

  def start_link(genre_file_path) do
    GenServer.start_link(__MODULE__, genre_file_path, name: __MODULE__)
  end

  @doc "A random genre, or nil if the genre list is empty."
  def get_genre() do
    GenServer.call(__MODULE__, :get_genre)
  end

  @doc """
  A random genre containing `keyword`, matched case-insensitively, or nil
  if nothing matches - a keyword nobody has a genre for is ordinary user
  input, not an error.
  """
  def get_genre(keyword) do
    GenServer.call(__MODULE__, {:get_genre, keyword})
  end

  ## server

  @impl true
  def init(genre_file_path) do
    genre_list =
      File.stream!(genre_file_path)
      |> Stream.map(&String.trim_trailing/1)
      |> Enum.to_list()

    {:ok, genre_list}
  end

  @impl true
  def handle_call(:get_genre, _from, genre_list) do
    {:reply, random_or_nil(genre_list), genre_list}
  end

  @impl true
  def handle_call({:get_genre, keyword}, _from, genre_list) do
    {:reply, random_or_nil(matching(genre_list, keyword)), genre_list}
  end

  @doc """
  The genres whose name contains `keyword`, ignoring case on both sides -
  somebody typing `\\qg Rock` means the same thing as `\\qg rock`.

  Only the name is matched, not the example track that follows it: `\\qg
  sky` asking for a genre shouldn't be answered with `rap - (e.g. Gucci
  Mane "Wake Up in the Sky")`. The full line is still what comes back,
  example and all.
  """
  def matching(genre_list, keyword) do
    keyword = String.downcase(keyword)

    Enum.filter(genre_list, fn genre ->
      genre |> name() |> String.downcase() |> String.contains?(keyword)
    end)
  end

  # Every line in `priv/genres.txt` is `<name> - (e.g. <artist> "<track>")`.
  # A line without the suffix is a bare name, so it is its own name.
  @example_separator " - (e.g."
  defp name(genre) do
    genre |> String.split(@example_separator, parts: 2) |> hd()
  end

  # `Enum.random/1` raises on an empty list, and this GenServer's caller is
  # the websocket connection - letting that exit propagate would drop the
  # bot off the socket over a keyword that matched nothing.
  defp random_or_nil([]), do: nil
  defp random_or_nil(list), do: Enum.random(list)
end
