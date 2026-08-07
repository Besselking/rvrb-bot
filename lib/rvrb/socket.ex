defmodule Rvrb.Socket do
  @moduledoc """
  The subset of the live connection that command handlers need.

  `Rvrb.WebSocket` is the real implementation and the default. Tests point
  `:rvrb, :socket` at a stub instead, so a handler's decision (which reply
  for which state) can be asserted on without a websocket.
  """

  @callback chat(message :: String.t()) :: any()
  @callback send_message(message :: map()) :: any()
  @callback send_queue(queue :: list()) :: any()
  @callback edit_user(params :: map()) :: any()

  @doc "The module implementing this behaviour, `Rvrb.WebSocket` unless overridden."
  def impl, do: Application.get_env(:rvrb, :socket, Rvrb.WebSocket)
end
