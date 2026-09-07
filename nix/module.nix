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
        `RVRB_SPOTIFY_SECRET_KEY`. Keep this out of the Nix store, mode
        0400, owned by `services.rvrb-bot.user` - e.g.
        `/var/lib/rvrb-bot/rvrb-bot.env`, or wherever agenix/sops-nix
        decrypts it to. Do not put it under `/run` unless a tool like
        sops-nix is actually re-creating it there on every activation -
        plain `/run` is tmpfs and a hand-placed file will vanish on
        reboot.
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
        `RVRB_SPOTIFY_CALLBACK_URL`, `RVRB_SPOTIFY_SCOPES`,
        `RVRB_LOG_LEVEL` (any `Logger` level; defaults to `info`), and
        `RVRB_BOT_ADMINS` (comma-separated RVRB user ids allowed to run
        the admin-only commands).
      '';
    };

    distribution = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run the release with Erlang distribution on, so another node on
          this machine can call into the bot - `Rvrb.Stats.snapshot/0` is
          what bes.is reads over it.

          Off by default: a single bot instance has no need for it, and
          the distribution port is effectively an unauthenticated admin
          socket for anyone who has the cookie. With this on,
          `RELEASE_COOKIE` becomes a real secret and has to come from
          `environmentFile` - the module refuses to build otherwise,
          rather than leave a known cookie in the world-readable Nix
          store.
        '';
      };

      nodeName = lib.mkOption {
        type = lib.types.str;
        default = "rvrb@127.0.0.1";
        description = ''
          The node name to register with EPMD, as `name@host`. The default
          keeps the node reachable only from this machine, which is all a
          reader running alongside it needs.
        '';
      };

      localOnly = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Bind EPMD and the distribution listener to the loopback
          interface, so a peer has to already be on this machine to reach
          either. Turn this off only with the distribution port behind a
          firewall or a tunnel - the protocol authenticates with the
          cookie and then sends everything in the clear.
        '';
      };
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
    assertions = [
      {
        assertion = !cfg.distribution.enable || cfg.environmentFile != null;
        message = ''
          services.rvrb-bot.distribution.enable needs an environmentFile
          setting RELEASE_COOKIE - with distribution on, any peer that can
          reach the port and knows the cookie can call into the node, so it
          must not come from the world-readable Nix store.
        '';
      }
    ];

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
          RVRB_TZDATA_DIR = "/var/lib/rvrb-bot/tzdata";
        }
        // (
          if cfg.distribution.enable then
            {
              RELEASE_DISTRIBUTION = "name";
              RELEASE_NODE = cfg.distribution.nodeName;
              # RELEASE_COOKIE is deliberately absent: it is a secret now,
              # so it comes from environmentFile (asserted below) rather
              # than from the store.
            }
            // lib.optionalAttrs cfg.distribution.localOnly {
              ERL_EPMD_ADDRESS = "127.0.0.1";
              ERL_AFLAGS = "-kernel inet_dist_use_interface {127,0,0,1}";
            }
          else
            {
              # A single bot instance has no need for distributed Erlang;
              # this also sidesteps nixpkgs' mixRelease stripping the
              # auto-generated releases/COOKIE file from the (immutable,
              # shared) store path, which would otherwise make the release
              # fail to boot entirely. The cookie's value is irrelevant
              # with distribution off, it just has to be set to something.
              RELEASE_DISTRIBUTION = "none";
              RELEASE_COOKIE = "unused-release-distribution-is-none";
            }
        )
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
