import Config

config :rvrb, Rvrb.Repo,
  database: "rvrb_repo",
  hostname: "localhost"

config :rvrb,
  ecto_repos: [Rvrb.Repo],
  bot_admins: ["635f69be2f9b8fe2ed7209f8"]

import_config "#{config_env()}.secret.exs"
