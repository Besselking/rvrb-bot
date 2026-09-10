defmodule Rvrb.AutoVote do
  @moduledoc """
  Decides whether the bot should cast, retract, or sit on an automatic
  dope/star for the track that's playing.

  The rule is unanimity among the DJs waiting behind the decks: when
  everyone queued up (the DJ currently playing doesn't get a say on their
  own track) has doped, the bot dopes too, and likewise for stars. Two
  things make that a decision rather than a one-way trigger:

    * The DJ queue moves while a track plays. Someone leaving can complete
      a unanimous vote that wasn't one a moment ago, and someone joining
      can break one - so the room's vote state has to be re-checked on
      every `updateChannelDjs`, not only on `updateChannelMeter`, and a
      vote already cast has to be retractable.

    * One queued DJ agreeing with themselves isn't a room consensus, so
      `@min_djs` DJs have to line up before the bot joins in. That floor
      only gates *starting* a vote: once the room has spoken, DJs dropping
      out of the queue below it doesn't unsay it, and the vote stands as
      long as nobody left disagrees.

  Everything here is a pure function of the state `Rvrb.WebSocket` already
  carries; the sending lives there.
  """

  # Below this many queued DJs, a unanimous vote is just one person's
  # opinion (or nobody's) - not enough to auto-vote on.
  @min_djs 2

  @doc """
  The DJs whose votes count: everyone in `djs` except whoever is playing
  right now (the head) and any bot in `bots`.

  Bots are dropped because this bot is usually one of them: waiting on its
  own vote before casting it deadlocks the check for as long as it's in
  the queue, and the same goes for any other bot that doesn't vote.
  """
  def deciding_djs(djs, bots \\ MapSet.new())

  def deciding_djs([], _bots), do: []

  def deciding_djs([_current_dj | queued], bots) do
    Enum.reject(queued, &MapSet.member?(bots, &1))
  end

  @doc """
  What to do about a vote the bot has (`voted?`) or hasn't cast, given the
  `voters` who have cast it and the `djs` whose votes count (from
  `deciding_djs/2`).

    * `:vote` - the queue is unanimous and big enough to act on.
    * `:retract` - the bot voted, and someone whose vote counts hasn't.
    * `:hold` - leave it as it is.

  An empty `djs` holds either way: with nobody queued there's no consensus
  to join, and a vote already cast isn't contradicted by an empty queue.
  """
  def decide(voted?, voters, djs)

  def decide(false, voters, djs) do
    if length(djs) >= @min_djs and unanimous?(voters, djs), do: :vote, else: :hold
  end

  def decide(true, voters, djs) do
    if djs != [] and not unanimous?(voters, djs), do: :retract, else: :hold
  end

  defp unanimous?(voters, djs), do: Enum.all?(djs, &(&1 in voters))

  @doc """
  The users who cast `vote_type` in an `updateChannelMeter` `voting`
  payload (`%{rvrb_id => %{"dope" => count, ...}}`).

  The `is_number/1` guard isn't ceremony: a payload that leaves the key
  out gives `nil`, and `nil > 0` is *true* under Elixir's term ordering,
  so a bare comparison would read a missing vote as a cast one.
  """
  def voters(voting, vote_type) do
    for {rvrb_id, votes} <- voting,
        count = votes[vote_type],
        is_number(count),
        count > 0,
        do: rvrb_id
  end

  @doc """
  The RVRB ids of the bots in an `updateChannelUsers` `users` payload.
  RVRB marks them with `"type" => "bot"`; everyone else carries no `type`
  at all.

  Called from the connection process, outside `Commands.run/5`'s net and
  outside the guard around the database write next to it - so an entry it
  can't read costs us that entry, the same way `User.update_users/1` drops
  a user it can't parse, rather than raising and dropping the connection
  with the track queue and the DJ list on it.
  """
  def bot_ids(users) when is_list(users) do
    for user <- users, is_map(user), user["type"] == "bot", into: MapSet.new(), do: user["_id"]
  end

  def bot_ids(_not_a_list), do: MapSet.new()
end
