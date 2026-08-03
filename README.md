# Rvrb

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

`mixFodDeps` in `flake.nix` pins the Hex dependencies from `mix.lock` with a
placeholder hash. The first `nix build` will fail and print the real hash -
paste it in and build again.

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
    environmentFile = "/run/secrets/rvrb-bot.env";
  };
}
```

`environmentFile` (keep it out of the Nix store, e.g. via agenix/sops-nix)
must set at least:

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
Spotify-backed commands. Non-secret overrides (`RVRB_DB_HOSTNAME`,
`RVRB_DB_NAME`, `RVRB_DB_PORT`, `RVRB_SPOTIFY_CALLBACK_URL`,
`RVRB_SPOTIFY_SCOPES`) go in `services.rvrb-bot.settings` instead. See
`nix/module.nix` for the full option list, including
`services.rvrb-bot.database.createLocally` to provision a local PostgreSQL
role and database.
