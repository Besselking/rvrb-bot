defmodule Rvrb.Wikipedia do
  @moduledoc """
  Looks an artist up on English Wikipedia and pulls out the passages that
  mention allegations, convictions, controversies and the like, so
  `\\artist` can print what the encyclopedia already says about them under
  the Spotify table.

  This says things about real people, so it errs toward saying nothing:

    * Passages are quoted verbatim from the article and shown with a link
      to it, rather than summarized into a verdict of our own. The reader
      judges; the bot only points.
    * The article has to be about a musician. The artist's name is
      resolved as an article title first (which follows redirects, so
      "Diddy" lands on "Sean Combs"), and only if that page is missing or
      isn't about music does it fall back to searching - where a hit also
      has to carry the same name as the artist, so an unknown artist can't
      pick up the controversies of whoever the search engine liked best.
      Two musicians who genuinely share a name are the case this can't
      tell apart; it takes the better known of them, which is the one a
      reader following the link will recognize as wrong.
    * Nothing found means nothing printed. Most artists match nothing,
      and a `\\artist` that stays a table is the normal case.

  The keyword list (`@keywords`) is deliberately made of terms that carry
  their meaning on their own - "convicted", "sexual assault", "plagiarism"
  - and skips ones that only look damning out of context. "Abuse" is the
  clearest example: "substance abuse" is in half the biographies on the
  site and says nothing about how somebody treated anybody, so only the
  compounds ("sexual abuse", "child abuse", "domestic abuse") are matched.
  Same reasoning keeps "criticized" and "cult" out: album reviews and cult
  classics would drown everything else. Bare "alleged" went the same way
  after it turned up a sentence about Boards of Canada allegedly having
  recorded 400 song fragments - it's ordinary encyclopedic hedging, and
  the accusations it does introduce ("alleged assault", "alleged
  plagiarism") are matched by the accusation itself.

  This is still a keyword scan, not comprehension - it will quote a
  sentence about an allegation somebody was cleared of, or one about a
  controversy an artist was on the receiving end of, exactly as readily as
  anything else. That's the other reason the passages are quoted rather
  than characterized.
  """

  alias Rvrb.Wikipedia.Api

  @article_base "https://en.wikipedia.org/wiki/"

  # How many search hits to look at when the artist's name doesn't resolve
  # to an article on its own. They come in one response either way, and
  # ten rather than five is what reaches the band Bread (rank five behind
  # the food, its history, and Panera) and Ghost (rank six).
  @max_candidates 10
  # How many passages to quote per artist. The point is "there is
  # something here, go read it", not a dossier.
  @max_passages 4
  # Longest quoted passage, in characters, before it's cut at a word
  # boundary. Wikipedia sentences run long, and this sits in a chat table.
  @max_passage_length 320

  # Terms worth quoting a sentence for. Each is matched whole-word and
  # case-insensitively - see the moduledoc for what's deliberately absent.
  @keywords [
    "controvers\\w+",
    "allegations?",
    "accus\\w+",
    "lawsuits?",
    "sued",
    "convicted",
    "convictions?",
    "guilty",
    "indicted",
    "indictments?",
    "criminal charges",
    "charged with",
    "arrested",
    "sentenced to",
    "imprisoned",
    "jailed",
    "restraining order",
    "settled out of court",
    "sexual assault",
    "sexual misconduct",
    "sexual abuse",
    "sexual harassment",
    "harassment",
    "harassed",
    "misconduct",
    "assaulted",
    "assault",
    "abusive",
    "child abuse",
    "domestic abuse",
    "domestic violence",
    "grooming",
    "groomed",
    "rape",
    "raped",
    "rapist",
    "statutory rape",
    "paedophil\\w+",
    "pedophil\\w+",
    "child pornography",
    "trafficking",
    "plagiaris\\w+",
    "plagiariz\\w+",
    "racis\\w+",
    "anti-?semit\\w+",
    "homophob\\w+",
    "transphob\\w+",
    "misogyn\\w+",
    # Qualified, because a bare "slur" is a notation mark about as often
    # as an insult in an article about a musician.
    "(racial|racist|ethnic|homophobic|transphobic) slurs?",
    "hate speech",
    "white supremac\\w+",
    "neo-nazi",
    "extremis[tm]\\w*",
    "death threats?",
    "scandals?",
    "backlash",
    "boycott\\w*",
    "fraud",
    "tax evasion",
    "money laundering",
    "banned from"
  ]

  @keyword_regex ~r/\b(?:#{Enum.join(@keywords, "|")})\b/iu

  # Sections whose contents are never worth quoting: citation titles and
  # track listings match keywords about as often as prose does.
  @skipped_sections ~r/^(references|external links|further reading|bibliography|notes|sources|discography|filmography|videography|awards( and nominations)?|track listing|see also)$/i

  # Roughly, "end of sentence": terminator (with the closing quote or
  # bracket that may follow it), then whitespace, then something that
  # starts a new sentence. The negative lookbehinds keep initials ("R.
  # Kelly") and the usual abbreviations from splitting a sentence in half.
  @sentence_split ~r/(?:(?<=[.!?])|(?<=[.!?]["'”’)\]]))(?<!\s[A-Z]\.)(?<!\bMr\.)(?<!\bMs\.)(?<!\bDr\.)(?<!\bSt\.)(?<!\bNo\.)(?<!\bvs\.)\s+(?=[A-Z"'“(\[])/u

  # A plaintext extract writes headings as `== Heading ==`, one per line.
  @heading_line ~r/^(={2,})\s*(.+?)\s*\1$/

  @doc """
  What English Wikipedia has on `artist_name`, as

      %{title: "Article title", url: "https://...", passages: [%{section: "Legal issues", text: "..."}]}

  or `nil` - no article, not a musician's article, nothing in it worth
  quoting, or Wikipedia not answering. Callers print nothing for `nil`,
  which is the common case.

  `api` is the module the requests go through, so a test can hand this a
  stub instead of reaching the network.
  """
  def controversies(artist_name, api \\ Api)

  def controversies(artist_name, api) when is_binary(artist_name) do
    with %{title: title} <- article(artist_name, api),
         {:ok, extract} <- api.extract(title),
         [_ | _] = passages <- passages(extract) do
      %{title: title, url: article_url(title), passages: passages}
    else
      _nothing -> nil
    end
  end

  def controversies(_artist_name, _api), do: nil

  @doc "The public article URL for `title`."
  def article_url(title), do: @article_base <> URI.encode(String.replace(title, " ", "_"))

  # The artist's own name as a title first: that's an exact hit where the
  # article is named after them, and Wikipedia resolves redirects along the
  # way ("Diddy" -> "Sean Combs"). Search is the fallback for a name
  # something else has taken (the band Bread, the band Ghost) or that
  # Wikipedia files under a longer title.
  #
  # Guessing disambiguated titles ("Bread (band)", "Air (band)") looks
  # like a surer bet than search and isn't: Wikipedia qualifies them by
  # nationality as readily as not ("Ghost (Swedish band)"), so the
  # guessable half of the convention finds *a* musician of that name
  # rather than the one playing - "Ghost (singer)" and "Air (singer)" are
  # both real articles about somebody else entirely.
  defp article(artist_name, api) do
    case api.page(artist_name) do
      {:ok, candidate} ->
        if artist_article?(candidate), do: candidate, else: searched_article(artist_name, api)

      _no_page ->
        searched_article(artist_name, api)
    end
  end

  defp searched_article(artist_name, api) do
    case api.search(artist_name, @max_candidates) do
      {:ok, candidates} ->
        Enum.find(
          candidates,
          &(artist_article?(&1) and same_subject?(&1.title, artist_name))
        )

      _no_results ->
        nil
    end
  end

  # Category names that say "this article is about a musician or a band".
  @artist_category ~r/\b(music\w*|singers?|songwriters?|rappers?|vocalists?|guitarists?|drummers?|bassists?|pianists?|keyboardists?|composers?|record producers?|disc jockeys?|djs?|bands?|girl groups?|boy bands?|recording artists?|discograph\w*)\b/i

  # ...and ones that say it isn't a person or a group at all. An album or
  # a song always carries its release year as a category ("2002 albums",
  # "2002 greatest hits albums"), and a disambiguation page always says
  # so, which is what these look for.
  @work_category ~r/(\b\d{4} [a-z\- ]*?(albums|songs|singles|extended plays|soundtracks|films)\b|\bdisambiguation\b)/i

  # A parenthesized disambiguator naming something other than a musical
  # act - "Foo (album)" and "Foo (Bar album)" are not the artist Foo,
  # "Foo (band)" is.
  @work_title ~r/\((\w+ )*(album|song|single|EP|mixtape|soundtrack|film|TV series|video game|novel|book|magazine|disambiguation)\)$/i

  @doc """
  Whether `candidate` (a `%{title: title, categories: categories}` from
  `Rvrb.Wikipedia.Api`) looks like the article about a musician or band,
  rather than an album, a song, a disambiguation page, or a subject that
  merely shares the artist's name.
  """
  def artist_article?(%{title: title, categories: categories}) do
    cond do
      title =~ @work_title -> false
      Enum.any?(categories, &(&1 =~ @work_category)) -> false
      true -> Enum.any?(categories, &(&1 =~ @artist_category))
    end
  end

  def artist_article?(_candidate), do: false

  @doc """
  Whether an article titled `title` is about somebody called
  `artist_name`, comparing the two with the disambiguator, case,
  punctuation and accents taken off - so "Tyler, the Creator" matches
  "Tyler, The Creator", and "Ye (rapper)" matches "Ye".

  This only guards the search fallback. A name that resolves to an article
  title directly is already as matched as it gets, redirect and all.
  """
  def same_subject?(title, artist_name) do
    normalize_name(title) == normalize_name(artist_name)
  end

  defp normalize_name(name) do
    name
    |> String.replace(~r/\s*\([^)]*\)\s*$/, "")
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  @doc """
  The passages of `extract` (a plaintext Wikipedia extract) worth showing,
  each a `%{section: heading_or_nil, text: sentence}` - at most
  #{@max_passages} of them.

  A sentence qualifies by matching a keyword. A section qualifies by its
  heading matching one ("Controversies", "Sexual assault allegations"), in
  which case its opening sentence is quoted even if no sentence in it
  matched on its own - the heading has already said what the section is.

  Passages from those sections come first: an article with a section named
  after the thing is the one case where Wikipedia has already done the
  judging, and it shouldn't fall off the end of the list behind a passing
  mention in the lead.
  """
  def passages(extract) when is_binary(extract) do
    extract
    |> sections()
    |> Enum.flat_map(&section_passages/1)
    |> Enum.sort_by(fn passage -> if passage.flagged_section?, do: 0, else: 1 end)
    |> Enum.take(@max_passages)
    |> Enum.map(&Map.take(&1, [:section, :text]))
  end

  def passages(_extract), do: []

  defp section_passages(%{heading: heading, text: text}) do
    if heading != nil and heading =~ @skipped_sections do
      []
    else
      flagged? = heading != nil and heading =~ @keyword_regex
      sentences = sentences(text)

      case Enum.filter(sentences, &mentions?/1) do
        [] -> if flagged?, do: Enum.take(sentences, 1), else: []
        matching -> matching
      end
      |> Enum.map(&%{section: heading, text: truncate(&1), flagged_section?: flagged?})
    end
  end

  @doc """
  Splits a plaintext extract into `%{heading: heading_or_nil, text: text}`
  sections. The lead - everything before the first heading - comes back
  with a `nil` heading.
  """
  def sections(extract) do
    extract
    |> String.split("\n")
    |> Enum.reduce([%{heading: nil, lines: []}], fn line, [current | rest] = sections ->
      case Regex.run(@heading_line, String.trim(line)) do
        [_line, _equals, heading] -> [%{heading: heading, lines: []} | sections]
        nil -> [%{current | lines: [line | current.lines]} | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn section ->
      %{heading: section.heading, text: section.lines |> Enum.reverse() |> Enum.join(" ")}
    end)
  end

  # Short quoted spans don't count toward a match. In an article about a
  # musician they are overwhelmingly song titles, which are edgy on
  # purpose - quoting Nirvana's article at somebody because it names
  # "Rape Me" is exactly the kind of noise that makes the rest of this
  # worth ignoring. Only the matching is blind to them: a sentence that
  # qualifies on its own prose is still shown whole, quotes and all.
  @quoted ~r/"[^"]{1,80}"/u

  defp mentions?(sentence), do: String.replace(sentence, @quoted, " ") =~ @keyword_regex

  defp sentences(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.split(@sentence_split)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp truncate(sentence) do
    if String.length(sentence) <= @max_passage_length do
      sentence
    else
      cut(sentence)
    end
  end

  # Back off to the last whole word, so a passage doesn't end mid-name.
  defp cut(sentence) do
    sentence
    |> String.slice(0, @max_passage_length)
    |> String.replace(~r/\s+\S*$/u, "")
    |> Kernel.<>("…")
  end

  @doc """
  Escapes `text` for chat and wraps the keywords that matched in
  `<strong>`, so the reason a passage is being shown is visible at a
  glance. Returns markup, for a caller to hand to chat as `{:safe, html}`.

  The keywords are plain words, so escaping first can't disturb them, and
  escaping first is what keeps the article's own text from arriving as
  markup.
  """
  def highlight(text) do
    text
    |> Html.escape()
    |> then(&Regex.replace(@keyword_regex, &1, "<strong>\\0</strong>"))
  end
end
