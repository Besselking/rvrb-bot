import Config

config :rvrb,
  ecto_repos: [Rvrb.Repo],
  bot_admins: ["635f69be2f9b8fe2ed7209f8"]

config :rvrb, Rvrb.Repo,
  database: "rvrb_repo",
  hostname: "localhost"

# dev/test read their secrets (bot token, DB credentials) from a local,
# gitignored file. prod has no such file - it gets everything at boot
# from the environment, see config/runtime.exs.
if config_env() in [:dev, :test] do
  import_config "#{config_env()}.secret.exs"
end
