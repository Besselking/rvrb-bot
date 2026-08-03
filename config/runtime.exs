import Config

# Evaluated at boot (mix phoenix-style), not at compile time - this is what
# lets a release built once (e.g. by Nix) be configured per-deployment via
# plain environment variables instead of baking secrets into the build.
if config_env() == :prod do
  config :rvrb, bot_token: System.fetch_env!("RVRB_BOT_TOKEN")

  config :rvrb, Rvrb.Repo,
    username: System.fetch_env!("RVRB_DB_USERNAME"),
    password: System.fetch_env!("RVRB_DB_PASSWORD"),
    database: System.get_env("RVRB_DB_NAME", "rvrb_repo"),
    hostname: System.get_env("RVRB_DB_HOSTNAME", "localhost"),
    port: String.to_integer(System.get_env("RVRB_DB_PORT", "5432"))

  # Optional: only needed for the Spotify-backed commands.
  if client_id = System.get_env("RVRB_SPOTIFY_CLIENT_ID") do
    config :spotify_ex,
      client_id: client_id,
      secret_key: System.fetch_env!("RVRB_SPOTIFY_SECRET_KEY"),
      callback_url: System.get_env("RVRB_SPOTIFY_CALLBACK_URL", ""),
      scopes: System.get_env("RVRB_SPOTIFY_SCOPES", "")
  end
end
