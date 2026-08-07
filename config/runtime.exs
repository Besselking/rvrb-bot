import Config

# Evaluated at boot (mix phoenix-style), not at compile time - this is what
# lets a release built once (e.g. by Nix) be configured per-deployment via
# plain environment variables instead of baking secrets into the build.
if config_env() == :prod do
  config :rvrb, bot_token: System.fetch_env!("RVRB_BOT_TOKEN")

  # `:info` (from config.exs) is the room-level story: connects, tracks, DJs,
  # commands. Turning this up to `debug` for a while is how you get the frame
  # dumps back out of a running deployment, without a rebuild.
  if level = System.get_env("RVRB_LOG_LEVEL") do
    config :logger, level: String.to_existing_atom(level)
  end

  repo_config = [
    username: System.fetch_env!("RVRB_DB_USERNAME"),
    database: System.get_env("RVRB_DB_NAME", "rvrb_repo"),
    port: String.to_integer(System.get_env("RVRB_DB_PORT", "5432"))
  ]

  # Postgrex prefers :socket_dir over :hostname when both are given, so this
  # only needs to pick which of the two (plus whether a password applies) to
  # add - unix-socket connections commonly rely on peer auth and need no
  # password at all.
  repo_config =
    case System.get_env("RVRB_DB_SOCKET_DIR") do
      nil ->
        repo_config ++
          [
            hostname: System.get_env("RVRB_DB_HOSTNAME", "localhost"),
            password: System.fetch_env!("RVRB_DB_PASSWORD")
          ]

      socket_dir ->
        repo_config = repo_config ++ [socket_dir: socket_dir]

        case System.get_env("RVRB_DB_PASSWORD") do
          nil -> repo_config
          password -> repo_config ++ [password: password]
        end
    end

  config :rvrb, Rvrb.Repo, repo_config

  # timex's tzdata dependency defaults to writing its update-tracking files
  # inside its own compiled priv dir, which is read-only once inside a
  # release. Point it somewhere writable instead.
  config :tzdata, :data_dir, System.get_env("RVRB_TZDATA_DIR", System.tmp_dir!())

  # Optional: only needed for the Spotify-backed commands.
  if client_id = System.get_env("RVRB_SPOTIFY_CLIENT_ID") do
    config :spotify_ex,
      client_id: client_id,
      secret_key: System.fetch_env!("RVRB_SPOTIFY_SECRET_KEY"),
      callback_url: System.get_env("RVRB_SPOTIFY_CALLBACK_URL", ""),
      scopes: System.get_env("RVRB_SPOTIFY_SCOPES", "")
  end
end
