{ self }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.rvrb-bot;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  options.services.rvrb-bot = {
    enable = lib.mkEnableOption "the rvrb bot";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.default;
      description = "The rvrb release package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "rvrb";
      description = "User account under which rvrb runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "rvrb";
      description = "Group account under which rvrb runs.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an EnvironmentFile (see systemd.exec(5)) holding secrets:
        at minimum `RVRB_BOT_TOKEN`, `RVRB_DB_USERNAME` and
        `RVRB_DB_PASSWORD`; optionally `RVRB_SPOTIFY_CLIENT_ID` and
        `RVRB_SPOTIFY_SECRET_KEY`. Keep this out of the Nix store (e.g. via
        agenix/sops-nix), mode 0400, owned by `services.rvrb-bot.user`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        RVRB_DB_HOSTNAME = "localhost";
        RVRB_DB_NAME = "rvrb_repo";
      };
      description = ''
        Extra, non-secret environment variables for the service, e.g.
        `RVRB_DB_HOSTNAME`, `RVRB_DB_NAME`, `RVRB_DB_PORT`,
        `RVRB_SPOTIFY_CALLBACK_URL`, `RVRB_SPOTIFY_SCOPES`.
      '';
    };

    database.createLocally = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Provision a local PostgreSQL database and role for rvrb via
        `services.postgresql`. The database is named the same as `user`
        (not `rvrb_repo`) - `ensureDBOwnership` only grants ownership of a
        database sharing the role's name, so this module sets
        `RVRB_DB_NAME` to match automatically. By default this also pairs
        with `database.socketDir`, so the role connects over the Unix
        socket and relies on peer auth (NixOS's default
        `services.postgresql` authentication trusts local socket
        connections from a matching OS user, and `user` here doubles as
        both) - no password required. If you instead set
        `settings.RVRB_DB_HOSTNAME` to force a TCP connection, you're
        responsible for an authentication rule and a `RVRB_DB_PASSWORD` in
        `environmentFile` yourself.
      '';
    };

    database.socketDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if cfg.database.createLocally then "/run/postgresql" else null;
      defaultText = lib.literalExpression ''if config.services.rvrb-bot.database.createLocally then "/run/postgresql" else null'';
      description = ''
        Directory holding the PostgreSQL Unix socket. When non-null, rvrb
        connects via this socket (`RVRB_DB_SOCKET_DIR`) instead of TCP, and
        `RVRB_DB_PASSWORD` becomes optional. Set to `null` to force a TCP
        connection via `settings.RVRB_DB_HOSTNAME` instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/rvrb-bot";
    };
    users.groups.${cfg.group} = { };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      # Without this, NixOS falls back to a stateVersion-derived default
      # package, which throws once that major version is dropped from
      # nixpkgs. mkDefault so an explicit choice elsewhere still wins.
      package = lib.mkDefault pkgs.postgresql;
      # ensureDBOwnership only grants ownership of a database named the
      # same as the role, so the database here is named after `user`.
      ensureDatabases = [ cfg.user ];
      ensureUsers = [
        {
          name = cfg.user;
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.services.rvrb-bot = {
      description = "rvrb bot";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ lib.optional cfg.database.createLocally "postgresql.service";
      wants = [ "network-online.target" ];
      requires = lib.optional cfg.database.createLocally "postgresql.service";

      environment =
        {
          RELEASE_TMP = "/var/lib/rvrb-bot/tmp";
          HOME = "/var/lib/rvrb-bot";
          # A single bot instance has no need for distributed Erlang; this
          # also sidesteps nixpkgs' mixRelease stripping the auto-generated
          # releases/COOKIE file from the (immutable, shared) store path,
          # which would otherwise make the release fail to boot entirely.
          # The cookie's value is irrelevant with distribution off, it just
          # has to be set to something.
          RELEASE_DISTRIBUTION = "none";
          RELEASE_COOKIE = "unused-release-distribution-is-none";
          RVRB_TZDATA_DIR = "/var/lib/rvrb-bot/tzdata";
        }
        // lib.optionalAttrs cfg.database.createLocally {
          RVRB_DB_NAME = cfg.user;
        }
        // lib.optionalAttrs (cfg.database.socketDir != null) {
          RVRB_DB_SOCKET_DIR = cfg.database.socketDir;
        }
        // cfg.settings;

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "/var/lib/rvrb-bot";
        StateDirectory = [
          "rvrb-bot"
          "rvrb-bot/tzdata"
        ];
        RuntimeDirectory = "rvrb-bot";
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        ExecStartPre = "${cfg.package}/bin/rvrb eval Rvrb.Release.migrate";
        ExecStart = "${cfg.package}/bin/rvrb start";
        ExecStop = "${cfg.package}/bin/rvrb stop";
        Restart = "on-failure";
        RestartSec = 5;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/rvrb-bot" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}
