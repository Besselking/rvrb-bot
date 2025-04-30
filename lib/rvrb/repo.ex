defmodule Rvrb.Repo do
  use Ecto.Repo,
    otp_app: :rvrb,
    adapter: Ecto.Adapters.Postgres
end
