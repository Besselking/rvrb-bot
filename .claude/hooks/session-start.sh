#!/bin/bash
set -euo pipefail

# Only needed for Claude Code on the web - local dev environments already
# have their own Elixir/Postgres setup.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_DIR="$CLAUDE_PROJECT_DIR"
ELIXIR_VERSION="1.18.3"
ELIXIR_DIR="/opt/elixir-${ELIXIR_VERSION}"

# --- System packages: Erlang/OTP runtime + Postgres server/client ---
if ! command -v erl >/dev/null 2>&1 || ! command -v psql >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq erlang postgresql unzip curl >/dev/null
fi

# --- Elixir itself: Ubuntu's apt package is ~1.14, but mix.exs requires "~> 1.18",
# so fetch a precompiled build matching the OTP 25 we just installed via apt.
if [ ! -x "${ELIXIR_DIR}/bin/elixir" ]; then
  curl -sSL -o /tmp/elixir-otp-25.zip \
    "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-25.zip"
  mkdir -p "${ELIXIR_DIR}"
  unzip -qo /tmp/elixir-otp-25.zip -d "${ELIXIR_DIR}"
  rm -f /tmp/elixir-otp-25.zip
fi

for bin in elixir elixirc iex mix; do
  ln -sf "${ELIXIR_DIR}/bin/${bin}" "/usr/local/bin/${bin}"
done

# Elixir's VM warns/misbehaves under the container's default POSIX locale.
export LANG=C.utf8
export LC_ALL=C.utf8
grep -qxF 'export LANG=C.utf8' "$CLAUDE_ENV_FILE" 2>/dev/null || echo 'export LANG=C.utf8' >> "$CLAUDE_ENV_FILE"
grep -qxF 'export LC_ALL=C.utf8' "$CLAUDE_ENV_FILE" 2>/dev/null || echo 'export LC_ALL=C.utf8' >> "$CLAUDE_ENV_FILE"

cd "$REPO_DIR"

# --- Local secrets: config/{dev,test}.secret.exs are gitignored on purpose
# (real deploys supply real secrets), so each fresh session needs stand-ins
# with enough to boot the app and connect to a local Postgres. This has to
# happen before ANY `mix` command, including `local.hex`/`local.rebar` -
# config/config.exs unconditionally imports these files as soon as Mix
# detects it's running inside this project, so even those fail without them.
if [ ! -f config/dev.secret.exs ]; then
  cat > config/dev.secret.exs << 'EOF'
import Config

config :rvrb, bot_token: "dev-bot-token"

config :rvrb, Rvrb.Repo,
  username: "root",
  password: "root"
EOF
fi

if [ ! -f config/test.secret.exs ]; then
  cat > config/test.secret.exs << 'EOF'
import Config

config :rvrb, bot_token: "test-bot-token"

config :rvrb, Rvrb.Repo,
  username: "root",
  password: "root"
EOF
fi

mix local.hex --if-missing >/dev/null
mix local.rebar --if-missing >/dev/null

mix deps.get >/dev/null

# --- Local Postgres, so Ecto-backed code has a real DB to run against ---
service postgresql start >/dev/null 2>&1 || true

su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='root'\"" 2>/dev/null | grep -q 1 || \
  su postgres -c "psql -c \"CREATE ROLE root WITH LOGIN SUPERUSER PASSWORD 'root';\"" >/dev/null

MIX_ENV=dev mix ecto.create >/dev/null 2>&1 || true
MIX_ENV=dev mix ecto.migrate >/dev/null 2>&1 || true
MIX_ENV=test mix ecto.create >/dev/null 2>&1 || true
MIX_ENV=test mix ecto.migrate >/dev/null 2>&1 || true

mix compile
