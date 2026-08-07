defmodule Rvrb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Rvrb.Repo] ++ connection_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rvrb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Everything that talks to the outside world - the websocket to RVRB
  # itself, and the two servers its handlers call into. Off in test, where
  # booting the app must not open a live socket with a fake token; a test
  # that needs one of these starts its own.
  defp connection_children do
    if Application.get_env(:rvrb, :start_connection, true) do
      [
        {Rvrb.WebSocket, Application.fetch_env!(:rvrb, :bot_token)},
        {Rvrb.GenreServer, Application.app_dir(:rvrb, "priv/genres.txt")},
        %{
          id: Rvrb.SpotifyServer,
          start: {Rvrb.SpotifyServer, :start_link, []}
        }
      ]
    else
      []
    end
  end
end
