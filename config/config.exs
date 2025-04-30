import Config

config :rvrb, Rvrb.Repo,
  database: "rvrb_repo",
  hostname: "localhost"

config :rvrb,
  ecto_repos: [Rvrb.Repo]

import_config "#{config_env()}.secret.exs"
