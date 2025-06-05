defmodule Rvrb.SpotifyUrl do
  # https://open.spotify.com/track/1HSVmNmRkrAyKahBe6Szx2?si=bc4ae348e57842ec
  # https://open.spotify.com/album/4e5dxIGtajnaLdMDSqxTrD?si=35e63279bf2a4c4c
  # <a href="https://open.spotify.com/album/4e5dxIGtajnaLdMDSqxTrD?si=35e63279bf2a4c4c" target="_blank"/>https://open.spotify.com/album/4e5dxIGtajnaLdMDSqxTrD?si=35e63279bf2a4c4c</a>

  def parse_path(path) do
    case path do
      "/album/" <> id -> {:album, id}
      "/track/" <> id -> {:track, id}
      other -> {:error, "unexpected spotify path: #{other}"}
    end
  end

  def parse(%URI{authority: "open.spotify.com", path: path}) do
    parse_path(path)
  end

  def parse(%URI{authority: other}) do
    {:error, "unexpected authority: #{other}"}
  end

  def parse("<a" <> _ = html_link) do
    case Regex.named_captures(~r/<a href="(?<href>[^"]+)"/, html_link) do
      %{"href" => href} -> parse(href)
      other -> {:error, "invalid Url: #{IO.inspect(html_link)}"}
    end
  end

  def parse(url) do
    uri = URI.parse(url)

    parse(uri)
  end
end
