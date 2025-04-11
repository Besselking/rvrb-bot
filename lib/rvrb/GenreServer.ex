defmodule Rvrb.GenreServer do
  use GenServer

  def start_link(genre_file_path) do
    GenServer.start_link(__MODULE__, genre_file_path, name: __MODULE__)
  end

  def get_genre() do
    GenServer.call(__MODULE__, :get_genre)
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
    {:reply, Enum.random(genre_list), genre_list}
  end
end
