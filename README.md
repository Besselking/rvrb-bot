# Rvrb

[![CI](https://github.com/Besselking/rvrb-bot/actions/workflows/ci.yml/badge.svg)](https://github.com/Besselking/rvrb-bot/actions/workflows/ci.yml)

**TODO: Add description**

## Nix

This repo ships a flake (`flake.nix`) that builds `rvrb` as an Elixir/OTP
release, plus a NixOS module (`nix/module.nix`) to run it as a systemd
service.

### Build / run

```
nix build   # -> ./result/bin/rvrb
nix run
```

`mixFodDeps` in `flake.nix` pins the Hex dependencies from `mix.lock` via a
fixed-output derivation hash. If you change `mix.lock` (add/remove/bump a
dependency), that hash goes stale - `nix build` will fail and print the new
one; paste it in and build again.

### Dev shell

```
nix develop   # elixir, erlang, postgresql on PATH
```

### As a NixOS service

```nix
{
  imports = [ rvrb-bot.nixosModules.default ];

  services.rvrb-bot = {
    enable = true;
    environmentFile = "/var/lib/rvrb-bot/rvrb-bot.env";
  };
}
```

`environmentFile` must point at a real, persistent path - keep it out of the
Nix store (world-readable) and **not** under `/run` (tmpfs, wiped on every
reboot). `/var/lib/rvrb-bot/rvrb-bot.env` (create it with `install -m 0400
-o rvrb -g rvrb`) works well since that directory already belongs to the
service. If you manage secrets with agenix/sops-nix instead, point this at
wherever those decrypt to (sops-nix's default, `/run/secrets/<name>`, is
fine there specifically because sops-nix re-creates it on every activation -
it just doesn't work for a file you place by hand).

It must set at least:

```
RVRB_BOT_TOKEN=...
RVRB_DB_USERNAME=...
RVRB_DB_PASSWORD=...
```

`RVRB_DB_PASSWORD` is only required for a TCP connection. If
`services.rvrb-bot.database.socketDir` is set (the default whenever
`database.createLocally = true`), rvrb connects via that Unix socket instead
and the password can be omitted, relying on peer auth.

Optionally set `RVRB_SPOTIFY_CLIENT_ID` / `RVRB_SPOTIFY_SECRET_KEY` for the
Spotify-backed commands. Non-secret overrides (`RVRB_BOT_ADMINS`,
`RVRB_DB_HOSTNAME`, `RVRB_DB_NAME`, `RVRB_DB_PORT`,
`RVRB_SPOTIFY_CALLBACK_URL`, `RVRB_SPOTIFY_SCOPES`, `RVRB_LOG_LEVEL`) go in
`services.rvrb-bot.settings` instead. See
`nix/module.nix` for the full option list, including
`services.rvrb-bot.database.createLocally` to provision a local PostgreSQL
role and database.

## Stats over distribution

`Rvrb.Stats.snapshot/0` returns everything a status page needs in one
term: what is playing right now, the DJ queue with its rotation estimate,
room-wide totals, per-day play counts, the leaderboards, and the last few
plays. It is read from outside the BEAM over ordinary Erlang
distribution - [bes.is](https://bes.is/rvrb) does it from .NET with
[BeamSharp](https://github.com/Besselking/BeamSharp), which dials this
node and issues:

```elixir
:erpc.call(:"rvrb@127.0.0.1", Rvrb.Stats, :snapshot, [])
```

Nothing new listens on a port for this, and nothing on the socket process
does any database work: the connection answers with a projection of state
it already holds (`Rvrb.WebSocket.State.snapshot/1`), and every query runs
in the caller's process.

The release runs with distribution **off** by default, so a reader needs
it turned on first:

```nix
services.rvrb-bot.distribution = {
  enable = true;
  nodeName = "rvrb@127.0.0.1";  # loopback-only, the default
};
```

With that on, `RELEASE_COOKIE` stops being a placeholder and has to be a
real secret in `environmentFile` alongside the bot token - anyone who can
reach the distribution port and knows the cookie can call into the node,
not just into `Rvrb.Stats`. `distribution.localOnly` (on by default) keeps
both EPMD and the distribution listener on loopback, so that "anyone" has
to already be on the machine.

## Logging

Everything goes through `Logger`. `dev` runs at `:debug` - every frame in
and out, plus the per-voter dump on each meter update. A release runs at
`:info`, which is the room-level story: connects, ready/join, track
changes, DJs coming and going, commands, and anything that went wrong.
Turn a running deployment up or down with `RVRB_LOG_LEVEL` (see above);
under systemd the output lands in the journal (`journalctl -u rvrb-bot`).
