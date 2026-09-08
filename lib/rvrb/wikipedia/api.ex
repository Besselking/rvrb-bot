defmodule Rvrb.Wikipedia.Api do
  @moduledoc """
  The three MediaWiki calls `Rvrb.Wikipedia` makes against English
  Wikipedia: resolve a title, search for one, and read an article's
  plaintext.

  Every function answers `:error` for anything that isn't the shape it
  wanted - a timeout, a rate limit, a missing page, a body that isn't the
  JSON we expected. The caller's fallback for all of those is the same
  (say nothing about this artist), so there's nothing for it to tell them
  apart by, and a chat command is not a place to raise from.

  Requests go out with a descriptive `User-Agent`, which the Wikimedia
  API's etiquette policy requires; anonymous clients get rate-limited or
  blocked outright.
  """

  @endpoint "https://en.wikipedia.org/w/api.php"
  @user_agent "rvrb-bot/0.1 (https://github.com/Besselking/rvrb-bot)"

  # These run inside the websocket connection process, in front of a chat
  # message somebody is waiting on. A slow Wikipedia is worth giving up
  # on quickly.
  @timeout :timer.seconds(4)

  @base_params %{
    "action" => "query",
    "format" => "json",
    # Pages come back as a list (with a `missing` flag on the ones that
    # don't exist) rather than as a map keyed by page id, which is the
    # only reason any of this can be pattern-matched comfortably.
    "formatversion" => "2",
    "redirects" => "1"
  }

  @doc """
  The article titled `title`, as `%{title: title, categories: categories}`,
  following redirects - so this is "the article this name means", not just
  "the article with this name".

  Hidden categories are left out. They're maintenance bookkeeping
  ("Articles with hCards"), and one of them - the MusicBrainz identifier
  category - sits on records and tours as readily as on the artists who
  made them, which is exactly the distinction `Rvrb.Wikipedia` reads these
  for.

  `:missing` when Wikipedia has no such page, and `:error` when the
  request didn't happen - a caller that caches its answers needs those to
  be different things.
  """
  def page(title) do
    params = %{
      "titles" => title,
      "prop" => "categories",
      "cllimit" => "max",
      "clshow" => "!hidden"
    }

    case get(params) do
      {:ok, %{"query" => %{"pages" => [page | _rest]}}} -> candidate(page)
      _error -> :error
    end
  end

  @doc """
  Up to `limit` search hits for `name`, in relevance order, each a
  `%{title: title, categories: categories}`.

  `{:ok, []}` when the search found nothing, `:error` when it didn't
  happen.
  """
  def search(name, limit) do
    params = %{
      "generator" => "search",
      "gsrsearch" => name,
      "gsrlimit" => to_string(limit),
      # Articles only - no talk pages, no categories, no help pages.
      "gsrnamespace" => "0",
      "prop" => "categories",
      "cllimit" => "max"
    }

    case get(params) do
      {:ok, %{"query" => %{"pages" => pages}}} ->
        # A generator's pages come back in no particular order; `index` is
        # what carries the search ranking.
        {:ok,
         pages
         |> Enum.sort_by(&Map.get(&1, "index", 0))
         |> Enum.flat_map(fn page ->
           case candidate(page) do
             {:ok, candidate} -> [candidate]
             :missing -> []
           end
         end)}

      {:ok, _no_hits} ->
        {:ok, []}

      _error ->
        :error
    end
  end

  @doc """
  The article's text with the markup taken off, headings kept as
  `== Heading ==` lines so `Rvrb.Wikipedia` can tell sections apart.

  The extract is the whole article, not the lead - which is why this is a
  request of its own: the extracts API only serves one full-text extract
  per call.
  """
  def extract(title) do
    params = %{
      "titles" => title,
      "prop" => "extracts",
      "explaintext" => "1",
      "exsectionformat" => "wiki",
      "exlimit" => "1"
    }

    case get(params) do
      {:ok, %{"query" => %{"pages" => [%{"extract" => extract} | _rest]}}}
      when is_binary(extract) and extract != "" ->
        {:ok, extract}

      _error ->
        :error
    end
  end

  defp candidate(%{"title" => title} = page) do
    if Map.get(page, "missing", false) do
      :missing
    else
      categories =
        page
        |> Map.get("categories")
        |> List.wrap()
        |> Enum.map(&Map.get(&1, "title", ""))

      {:ok, %{title: title, categories: categories}}
    end
  end

  defp candidate(_page), do: :missing

  defp get(params) do
    url = @endpoint <> "?" <> URI.encode_query(Map.merge(@base_params, params))

    case HTTPoison.get(url, [{"user-agent", @user_agent}],
           timeout: @timeout,
           recv_timeout: @timeout
         ) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
        JSON.decode(body)

      _error ->
        :error
    end
  end
end
