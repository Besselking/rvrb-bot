import Config

# The suite must not open a real websocket to RVRB (with the fake token
# from test.secret.exs, no less) or reach out to Spotify just because it
# booted the app - see `Rvrb.Application.start/2`.
config :rvrb, start_connection: false

# Its own database, so a run can't roll back or truncate whatever is in
# the dev one, and the sandbox pool so each test gets a transaction that
# is never committed.
config :rvrb, Rvrb.Repo,
  database: "rvrb_repo_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# A passing run logs every statement the DB-backed tests make otherwise,
# which buries the actual failures.
config :logger, level: :warning
