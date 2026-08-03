#!/bin/bash
set -euo pipefail

# Only needed for Claude Code on the web - local dev environments already
# have their own Elixir/Postgres setup.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_DIR="$CLAUDE_PROJECT_DIR"
OTP_VERSION="27.3"
OTP_DIR="/opt/otp-${OTP_VERSION}"
ELIXIR_VERSION="1.20.2"
ELIXIR_DIR="/opt/elixir-${ELIXIR_VERSION}"

# --- System packages: build deps for Erlang/OTP + Postgres server/client.
# mix.exs requires Elixir "~> 1.20", whose precompiled builds only target
# OTP 27+, and Ubuntu's apt-provided erlang is stuck on OTP 25 - so OTP has
# to be built from source instead of installed from apt.
if ! command -v psql >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || [ ! -x "${OTP_DIR}/bin/erl" ]; then
  apt-get update -qq
  apt-get install -y -qq \
    build-essential autoconf m4 libncurses-dev libssl-dev \
    postgresql unzip curl >/dev/null
fi

# --- Erlang/OTP: built from source, once per container (cached afterward).
# Skips the optional GUI/tooling apps (wx, debugger, observer, et, megaco,
# diameter, jinterface, odbc, docs) this bot never touches, to keep the
# build reasonably fast.
if [ ! -x "${OTP_DIR}/bin/erl" ]; then
  OTP_BUILD_DIR="/tmp/otp-build"
  rm -rf "$OTP_BUILD_DIR"
  mkdir -p "$OTP_BUILD_DIR"
  curl -sSL -o "${OTP_BUILD_DIR}/otp_src.tar.gz" \
    "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz"
  tar xzf "${OTP_BUILD_DIR}/otp_src.tar.gz" -C "$OTP_BUILD_DIR"
  (
    cd "${OTP_BUILD_DIR}/otp_src_${OTP_VERSION}"
    ./configure --prefix="$OTP_DIR" \
      --without-wx --without-debugger --without-observer --without-et \
      --without-megaco --without-diameter --without-jinterface \
      --without-odbc --without-docs >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
  )
  rm -rf "$OTP_BUILD_DIR"
fi

# --- Elixir itself: precompiled build matching the OTP major we just built.
if [ ! -x "${ELIXIR_DIR}/bin/elixir" ]; then
  curl -sSL -o /tmp/elixir-otp-27.zip \
    "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-27.zip"
  mkdir -p "${ELIXIR_DIR}"
  unzip -qo /tmp/elixir-otp-27.zip -d "${ELIXIR_DIR}"
  rm -f /tmp/elixir-otp-27.zip
fi

# Erlang ships many binaries (erl, erlc, escript, dialyzer, ...) - put the
# whole bin dir on PATH rather than symlinking each one individually.
export PATH="${OTP_DIR}/bin:${PATH}"
grep -qxF "export PATH=\"${OTP_DIR}/bin:\$PATH\"" "$CLAUDE_ENV_FILE" 2>/dev/null || \
  echo "export PATH=\"${OTP_DIR}/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"

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
