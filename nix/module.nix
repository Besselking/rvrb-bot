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
        `services.postgresql`. rvrb still connects over TCP (see
        `RVRB_DB_HOSTNAME`), so you are responsible for an authentication
        rule (`services.postgresql.authentication`) and a matching
        `RVRB_DB_PASSWORD` in `environmentFile` - this option only creates
        the database and role, it does not set a password.
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
      ensureDatabases = [ "rvrb_repo" ];
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

      environment = {
        RELEASE_TMP = "/var/lib/rvrb-bot/tmp";
        HOME = "/var/lib/rvrb-bot";
      } // cfg.settings;

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "/var/lib/rvrb-bot";
        StateDirectory = "rvrb-bot";
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
