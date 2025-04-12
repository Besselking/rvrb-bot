defmodule Rvrb.GenreServer do
  use GenServer

  def start_link(genre_file_path) do
    GenServer.start_link(__MODULE__, genre_file_path, name: __MODULE__)
  end

  def get_genre() do
    GenServer.call(__MODULE__, :get_genre)
  end

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
    {:reply, Enum.random(genre_list), genre_list}
  end

  @impl true
  def handle_call({:get_genre, keyword}, _from, genre_list) do

    sub_list = Enum.filter(genre_list, fn(genre) ->
      String.contains?(genre, keyword)
    end)

    {:reply, Enum.random(sub_list), genre_list}
  end
end
