defmodule Rvrb.Api do
  @moduledoc """
  The few RVRB HTTP routes the bot calls, authenticated with the bot's API
  key as a bearer token - the same key the websocket connects with.

  RVRB moved two operations off the websocket and onto these routes:
  reordering the DJ queue (`PUT /api/channel/{channelId}/djs`) and editing
  a profile (`PATCH /api/users/{userId}`). Both return `:ok` or
  `{:error, message}`, with a message fit for chat.
  """

  require Logger

  @default_url "https://app.rvrb.one"
  @timeout :timer.seconds(10)

  @doc "Puts the DJs in `djs` (RVRB user ids) in that order."
  def put_djs(channel_id, djs) when is_binary(channel_id) and is_list(djs) do
    request(:put, "/api/channel/#{URI.encode_www_form(channel_id)}/djs", %{djs: djs})
  end

  def put_djs(_channel_id, _djs), do: {:error, "the bot has not joined a channel yet"}

  @doc """
  Updates the profile of `user_id` - for the bot, its own id. `params` holds
  any of `displayName`, `image`, `djImage`, `thumbsUpImage`,
  `thumbsDownImage` and `bio`.
  """
  def patch_user(user_id, params) when is_binary(user_id) and is_map(params) do
    request(:patch, "/api/users/#{URI.encode_www_form(user_id)}", params)
  end

  def patch_user(_user_id, _params), do: {:error, "I don't know my own user id yet"}

  defp request(method, path, body) do
    url = base_url() <> path
    headers = [{"authorization", "Bearer #{token()}"}, {"content-type", "application/json"}]

    case HTTPoison.request(method, url, JSON.encode!(body), headers, recv_timeout: @timeout) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in 200..299 ->
        :ok

      {:ok, %HTTPoison.Response{status_code: status, body: response}} ->
        Logger.warning("#{method} #{path} answered #{status}: #{inspect(response)}")
        {:error, "RVRB answered #{status}#{error_detail(response)}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("#{method} #{path} failed: #{inspect(reason)}")
        {:error, "the request to RVRB failed"}
    end
  end

  # RVRB's error bodies are `{"message": "..."}` or plain text; anything
  # else is not worth repeating in chat.
  defp error_detail(response) do
    case JSON.decode(response) do
      {:ok, %{"message" => message}} when is_binary(message) -> ": " <> Html.escape(message)
      _not_json_message -> ""
    end
  end

  defp base_url, do: Application.get_env(:rvrb, :api_url, @default_url)
  defp token, do: Application.fetch_env!(:rvrb, :bot_token)
end
