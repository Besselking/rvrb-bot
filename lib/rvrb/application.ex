defmodule Rvrb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Rvrb.Worker.start_link(arg)
      # {Rvrb.Worker, arg}
      {Rvrb.WebSocket, Application.fetch_env!(:rvrb, :bot_token)},
      {Rvrb.GenreServer, "./genres.txt"},
      %{
        id: Rvrb.SpotifyServer,
        start: {Rvrb.SpotifyServer, :start_link, []}
      },
      Rvrb.Repo
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rvrb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
