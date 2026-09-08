defmodule Rvrb.WikipediaTest do
  use ExUnit.Case, async: true

  alias Rvrb.Wikipedia

  @extract """
  Robert Sylvester Kelly (born January 8, 1967), known professionally as R. Kelly, is an American singer and songwriter. He was convicted of racketeering and sex trafficking in 2021.


  == Early life ==

  Kelly was born on the South Side of Chicago and attended Kenwood Academy.


  == Musical career ==

  His debut solo album, 12 Play, sold six million copies.


  == Sexual abuse allegations and trials ==

  Beginning in the 1990s, Kelly was the subject of multiple allegations of sexual abuse involving minors. He was acquitted in a 2008 child pornography trial.


  == Discography ==

  12 Play (1993). Controversy sells albums.


  == References ==

  "Singer accused of assault", Chicago Tribune, 2002.
  """

  # `Rvrb.Wikipedia.Api` stand-in: each function answers from a map the
  # test put in the process dictionary.
  defmodule StubApi do
    # The defaults are the answers Wikipedia gives for a subject it simply
    # doesn't have: no page, and a search that turned nothing up. A test
    # that wants a *failed* request stubs `:error` for it explicitly -
    # that's the distinction the cache is built on.
    def page(title), do: canned(:page, title, :missing)
    def search(name, _limit), do: canned(:search, name, {:ok, []})
    def extract(title), do: canned(:extract, title, :error)

    defp canned(call, key, default) do
      :wikipedia_api
      |> Process.get(%{})
      |> Map.get(call, %{})
      |> Map.get(key, default)
    end
  end

  defp stub_api(calls), do: Process.put(:wikipedia_api, calls)

  defp musician(title) do
    {:ok, %{title: title, categories: ["Living people", "American singers"]}}
  end

  describe "sections/1" do
    test "splits an extract on its headings, with the lead under no heading" do
      assert [lead | rest] = Wikipedia.sections(@extract)

      assert lead.heading == nil
      assert lead.text =~ "known professionally as R. Kelly"

      assert Enum.map(rest, & &1.heading) == [
               "Early life",
               "Musical career",
               "Sexual abuse allegations and trials",
               "Discography",
               "References"
             ]
    end

    test "an extract with no headings is one section" do
      assert [%{heading: nil, text: text}] = Wikipedia.sections("Just the lead. Nothing else.")
      assert text =~ "Just the lead."
    end
  end

  describe "passages/1" do
    test "quotes the sentences that mention something, and nothing else" do
      texts = @extract |> Wikipedia.passages() |> Enum.map(& &1.text)

      assert Enum.any?(texts, &(&1 =~ "multiple allegations of sexual abuse"))
      assert Enum.any?(texts, &(&1 =~ "convicted of racketeering"))
      refute Enum.any?(texts, &(&1 =~ "Kenwood Academy"))
      refute Enum.any?(texts, &(&1 =~ "sold six million copies"))
    end

    test "a section named after the thing comes before a passing mention in the lead" do
      assert [first | _rest] = Wikipedia.passages(@extract)
      assert first.section == "Sexual abuse allegations and trials"
    end

    test "skips citation lists and track listings, where a keyword means nothing" do
      sections = @extract |> Wikipedia.passages() |> Enum.map(& &1.section)

      refute "References" in sections
      refute "Discography" in sections
    end

    test "quotes the opening sentence of a flagged section that says nothing quotable itself" do
      extract = """
      Someone is a musician.


      == Controversies ==

      In 2019 they said something on stage that upset a lot of people. It was in all the papers.
      """

      assert [%{section: "Controversies", text: text}] = Wikipedia.passages(extract)
      assert text =~ "said something on stage"
    end

    test "leaves ordinary encyclopedic hedging alone" do
      extract =
        "Geogaddi allegedly involved the creation of 400 song fragments, of which 22 were used."

      assert Wikipedia.passages(extract) == []
    end

    test "doesn't quote an article for the name of a song" do
      extract =
        ~s(The network refused to let the band play "Rape Me", so Cobain sang "Lithium" instead.)

      assert Wikipedia.passages(extract) == []
    end

    test "still quotes a sentence whose own prose matches, quotes and all" do
      extract = ~s(He was convicted in 2021, months after releasing "Rape Me".)

      assert [%{text: text}] = Wikipedia.passages(extract)
      assert text =~ "Rape Me"
    end

    test "finds nothing in an article that says nothing" do
      extract = """
      Aphex Twin is an Irish-British musician.


      == Career ==

      He founded Rephlex Records and released Selected Ambient Works 85-92.
      """

      assert Wikipedia.passages(extract) == []
    end

    test "quotes at most a handful of passages" do
      extract =
        "Intro. " <>
          Enum.map_join(1..10, " ", fn n -> "In 200#{n} they were accused of something." end)

      assert length(Wikipedia.passages(extract)) == 4
    end

    test "cuts an overlong sentence at a word boundary" do
      long = String.duplicate("something happened and then ", 30)
      assert [%{text: text}] = Wikipedia.passages("They were accused of " <> long <> "things.")

      assert String.length(text) <= 321
      assert String.ends_with?(text, "…")
      refute text =~ ~r/\s…$/
    end

    test "measures a passage in characters, not bytes" do
      # 271 characters, but 321 bytes - under the limit either way you'd
      # want to read it, so it comes back whole.
      sentence = "They were accused of " <> String.duplicate("café ", 50) <> "things."

      assert [%{text: text}] = Wikipedia.passages(sentence)
      refute String.ends_with?(text, "…")
    end

    test "ends a sentence at a closing quote" do
      extract =
        ~s(Cobain said "I wanted a name that was pretty." The band were later sued over the name.)

      assert [%{text: text}] = Wikipedia.passages(extract)
      assert text == "The band were later sued over the name."
    end

    test "keeps an initial from splitting a sentence in half" do
      extract = "The album was produced by R. Kelly. He was later convicted of racketeering."

      assert [%{text: text}] = Wikipedia.passages(extract)
      assert text == "He was later convicted of racketeering."
    end

    test "isn't handed anything but a string" do
      assert Wikipedia.passages(nil) == []
    end
  end

  describe "artist_article?/1" do
    test "takes an article about a musician" do
      assert Wikipedia.artist_article?(%{
               title: "Ye (rapper)",
               categories: ["Living people", "American rappers"]
             })
    end

    test "leaves an article about one of their records" do
      refute Wikipedia.artist_article?(%{
               title: "Ye (album)",
               categories: ["2018 albums", "Kanye West albums"]
             })
    end

    test "leaves a record whose disambiguator names the artist too" do
      refute Wikipedia.artist_article?(%{
               title: "Nirvana (Nirvana album)",
               categories: ["2002 greatest hits albums", "Nirvana (band) compilation albums"]
             })
    end

    test "leaves a disambiguation page" do
      refute Wikipedia.artist_article?(%{
               title: "Genesis",
               categories: ["Disambiguation pages with short descriptions"]
             })
    end

    test "leaves a subject that just happens to share the name" do
      refute Wikipedia.artist_article?(%{title: "Air", categories: ["Breathing gases"]})
    end
  end

  describe "same_subject?/2" do
    test "ignores the disambiguator, case, punctuation and accents" do
      assert Wikipedia.same_subject?("Ye (rapper)", "Ye")
      assert Wikipedia.same_subject?("Tyler, the Creator", "Tyler, The Creator")
      assert Wikipedia.same_subject?("Sigur Rós", "Sigur Ros")
    end

    test "doesn't match a different name" do
      refute Wikipedia.same_subject?("Bread (band)", "Butter")
      refute Wikipedia.same_subject?("Sean Combs", "Diddy")
    end
  end

  describe "highlight/1" do
    test "escapes the article's text and marks up what matched" do
      assert Wikipedia.highlight(~s(He was <accused> of "assault" & convicted.)) ==
               "He was &lt;<strong>accused</strong>&gt; of &quot;<strong>assault</strong>&quot;" <>
                 " &amp; <strong>convicted</strong>."
    end
  end

  describe "controversies/2" do
    test "reads the article the artist's name resolves to" do
      stub_api(%{
        page: %{"R. Kelly" => musician("R. Kelly")},
        extract: %{"R. Kelly" => {:ok, @extract}}
      })

      assert {:ok, %{title: "R. Kelly", url: url, passages: [_ | _]}} =
               Wikipedia.controversies("R. Kelly", StubApi)

      assert url == "https://en.wikipedia.org/wiki/R._Kelly"
    end

    test "searches when the name titles something that isn't a musician" do
      stub_api(%{
        page: %{"Bread" => {:ok, %{title: "Bread", categories: ["Staple foods"]}}},
        search: %{
          "Bread" =>
            {:ok,
             [
               %{title: "Bread", categories: ["Staple foods"]},
               %{title: "Bread (band)", categories: ["American soft rock music groups"]}
             ]}
        },
        extract: %{"Bread (band)" => {:ok, @extract}, "Bread" => {:ok, @extract}}
      })

      assert {:ok, %{title: "Bread (band)"}} = Wikipedia.controversies("Bread", StubApi)
    end

    test "takes the first search hit that is a musician of that name" do
      stub_api(%{
        search: %{
          "Ye" =>
            {:ok,
             [
               %{title: "Ye (album)", categories: ["2018 albums"]},
               %{title: "Ye (rapper)", categories: ["American rappers"]}
             ]}
        },
        extract: %{"Ye (rapper)" => {:ok, @extract}}
      })

      assert {:ok, %{title: "Ye (rapper)"}} = Wikipedia.controversies("Ye", StubApi)
    end

    test "won't quote an article about somebody else with a better ranked name" do
      stub_api(%{
        search: %{
          "Some Unknown Band" => {:ok, [%{title: "R. Kelly", categories: ["American singers"]}]}
        },
        extract: %{"R. Kelly" => {:ok, @extract}}
      })

      assert Wikipedia.controversies("Some Unknown Band", StubApi) == {:ok, nil}
    end

    test "says nothing about an artist whose article says nothing" do
      stub_api(%{
        page: %{"Aphex Twin" => musician("Aphex Twin")},
        extract: %{"Aphex Twin" => {:ok, "Aphex Twin is an Irish-British musician."}}
      })

      assert Wikipedia.controversies("Aphex Twin", StubApi) == {:ok, nil}
    end

    test "an artist Wikipedia has never heard of is an answer, not a failure" do
      stub_api(%{})

      assert Wikipedia.controversies("Nobody At All", StubApi) == {:ok, nil}
    end

    test "a lookup that didn't happen is not an answer" do
      stub_api(%{page: %{"R. Kelly" => :error}})

      assert Wikipedia.controversies("R. Kelly", StubApi) == :error
    end

    test "a search that didn't happen is not an answer either" do
      stub_api(%{search: %{"R. Kelly" => :error}})

      assert Wikipedia.controversies("R. Kelly", StubApi) == :error
    end

    test "an article it found but couldn't read is not an answer" do
      stub_api(%{page: %{"R. Kelly" => musician("R. Kelly")}})

      assert Wikipedia.controversies("R. Kelly", StubApi) == :error
    end

    test "says nothing for an artist with no name" do
      assert Wikipedia.controversies(nil, StubApi) == {:ok, nil}
    end
  end
end
