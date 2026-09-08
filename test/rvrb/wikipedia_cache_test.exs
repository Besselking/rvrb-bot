defmodule Rvrb.Wikipedia.CacheTest do
  use ExUnit.Case, async: true

  alias Rvrb.Wikipedia.Cache

  # Answers like `Rvrb.Wikipedia.Api`, and tells the test process about
  # every request it was asked to make - the point of a cache is the
  # requests that stop happening.
  defmodule CountingApi do
    def page(title) do
      send(owner(), {:api, :page, title})

      case Process.get(:page_answer, :ok) do
        :ok -> {:ok, %{title: title, categories: ["American singers"]}}
        other -> other
      end
    end

    def search(name, _limit) do
      send(owner(), {:api, :search, name})
      {:ok, []}
    end

    def extract(title) do
      send(owner(), {:api, :extract, title})
      Process.get(:extract_answer, {:ok, "Somebody is a musician. They were convicted in 2021."})
    end

    defp owner, do: Process.get(:owner, self())
  end

  defp start_cache(opts \\ []) do
    name = :"cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, Keyword.merge([name: name], opts)})
    name
  end

  defp controversies(name, server),
    do: Cache.controversies(name, server: server, api: CountingApi)

  # Empties the mailbox, so a `refute_received` after it is about the
  # requests the next call makes rather than the ones before it.
  defp drain do
    receive do
      {:api, _call, _argument} -> drain()
    after
      0 -> :ok
    end
  end

  setup do
    Process.put(:owner, self())
    :ok
  end

  test "asks Wikipedia once for an artist, however often it's asked" do
    cache = start_cache()

    assert %{title: "R. Kelly"} = controversies("R. Kelly", cache)
    assert_received {:api, :page, "R. Kelly"}
    assert_received {:api, :extract, "R. Kelly"}
    drain()

    assert %{title: "R. Kelly"} = controversies("R. Kelly", cache)
    refute_received {:api, _call, _argument}
  end

  test "remembers an artist there was nothing to say about, which is most of them" do
    cache = start_cache()
    Process.put(:extract_answer, {:ok, "Somebody is a musician who kept to themselves."})

    assert controversies("Aphex Twin", cache) == nil
    assert_received {:api, :page, "Aphex Twin"}
    drain()

    assert controversies("Aphex Twin", cache) == nil
    refute_received {:api, _call, _argument}
  end

  test "doesn't remember a lookup that failed" do
    cache = start_cache()
    Process.put(:page_answer, :error)

    assert controversies("R. Kelly", cache) == nil
    assert_received {:api, :page, "R. Kelly"}

    # A throttled minute costs one command its passages, not the rest of
    # the day's.
    drain()
    Process.delete(:page_answer)
    assert %{title: "R. Kelly"} = controversies("R. Kelly", cache)
    assert_received {:api, :page, "R. Kelly"}
  end

  test "looks again once an answer has gone stale" do
    cache = start_cache(ttl: 0)

    assert %{title: "R. Kelly"} = controversies("R. Kelly", cache)
    assert_received {:api, :page, "R. Kelly"}
    drain()

    assert %{title: "R. Kelly"} = controversies("R. Kelly", cache)
    assert_received {:api, :page, "R. Kelly"}
  end

  test "makes room for a new artist by dropping the oldest" do
    cache = start_cache(max_entries: 2)

    for name <- ["First", "Second", "Third"] do
      assert %{} = controversies(name, cache)
    end

    drain()

    # "First" was pushed out; the two after it are still there.
    assert %{} = controversies("Second", cache)
    assert %{} = controversies("Third", cache)
    refute_received {:api, _call, _argument}

    assert %{} = controversies("First", cache)
    assert_received {:api, :page, "First"}
  end

  test "a cache that isn't running just means an uncached lookup" do
    assert %{title: "R. Kelly"} =
             Cache.controversies("R. Kelly", server: :no_such_cache, api: CountingApi)

    assert_received {:api, :page, "R. Kelly"}
  end
end
