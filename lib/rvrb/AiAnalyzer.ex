defmodule AiAnalyzer do
    alias Rvrb.SpotifyServer
    def analyze(%{"id" => artist_id}) do
        artist = SpotifyServer.artist(artist_id)
    end
end
