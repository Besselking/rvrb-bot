defmodule Rvrb.SpotifyError do
  @moduledoc """
  Raised when a Spotify request doesn't come back with an answer.

  `Spotify.Responder` collapses everything that isn't a 2xx-with-a-body
  into `{:error, reason}`, and the read functions in `Rvrb.SpotifyServer`
  used to match `{:ok, _}` straight against that. A host that couldn't
  reach Spotify therefore surfaced as

      ** (MatchError) no match of right hand side value: {:error, :closed}

  which is true, names neither Spotify nor the request, and sends whoever
  reads it to the source to learn either. That cost a long evening once.

  `reason` is whatever came back: a hackney reason (`:closed`, `:timeout`,
  `:econnrefused`) when the request never completed, or Spotify's decoded
  error body when it answered with one. `request` says which read asked.
  """

  defexception [:reason, :request]

  @impl true
  def message(%__MODULE__{reason: reason, request: request}) do
    "Spotify #{request} failed: #{inspect(reason)}" <> hint(reason)
  end

  # These say nothing about Spotify and everything about the host's
  # egress - `Rvrb.SpotifyServer.get/2` has already retried on a fresh,
  # unpooled connection by the time one gets this far, so the pool isn't
  # it either. Worth spelling out once in the log rather than leaving a
  # bare atom to be interpreted.
  @connection_reasons [
    :closed,
    :timeout,
    :connect_timeout,
    :econnrefused,
    :econnreset,
    :ehostunreach,
    :enetunreach,
    :nxdomain
  ]

  defp hint(reason) when reason in @connection_reasons do
    " - the request never completed, so check that this host can reach api.spotify.com"
  end

  defp hint(_reason), do: ""
end
