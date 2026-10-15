{
  config,
  lib,
  pkgs,
  ...
}:

let
  policy = import ../modules/ferrix-backup-policy.nix;
  stateDirectory = "/var/lib/ferrix-backup";
  health = lib.getExe config.system.build.ferrixBackupHealth;
  secret = name: config.sops.secrets."ferrix-backup/${name}".path;
  hosts = {
    hoth = "hoth.tailbb897.ts.net";
    borgbase = "hlek3m3n.repo.borgbase.com";
  };
  databaseRoots = [
    "/var/lib/inigo/.hermes"
    # DynamicUser puts SilverBullet's actual files here, behind a symlink.
    "/var/lib/private/silverbullet"
    "/var/lib/remote-pi-relay"
  ];
  sources = [
    "/home/mpfammatter"
    "/var/lib/inigo"
    "/var/lib/private/silverbullet"
    "/var/lib/remote-pi-relay"
    "/var/lib/docker/volumes/zulip_zulip/_data"
    "${stateDirectory}/sqlite"
    "${stateDirectory}/zulip"
    "/etc/ferrix-backup-recovery"
  ];
  sshCommand =
    destination:
    lib.concatStringsSep " " [
      "${pkgs.openssh}/bin/ssh"
      "-i ${secret "${destination}-ssh-key"}"
      "-o BatchMode=yes"
      "-o IdentitiesOnly=yes"
      "-o StrictHostKeyChecking=yes"
      "-o UserKnownHostsFile=${policy.knownHostsFile}"
      "-o GlobalKnownHostsFile=/dev/null"
      "-o ConnectTimeout=30"
      "-o ServerAliveInterval=30"
      "-o ServerAliveCountMax=3"
    ];
  borgEnvironment = destination: {
    BORG_REPO = policy.repositories.${destination};
    BORG_RSH = sshCommand destination;
    BORG_PASSCOMMAND = "${pkgs.coreutils}/bin/cat ${secret "${destination}-passphrase"}";
    BORG_CACHE_DIR = "/var/cache/ferrix-backup/${destination}";
    BORG_SECURITY_DIR = "${stateDirectory}/security/${destination}";
    BORG_KEYS_DIR = "${stateDirectory}/keys/${destination}";
  };
  borgWrapper =
    destination:
    pkgs.writeShellScriptBin "ferrix-borg-${destination}" ''
      set -euo pipefail
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") (
          borgEnvironment destination
        )
      )}
      exec ${pkgs.borgbackup}/bin/borg "$@"
    '';
  commonSettings = {
    source_directories = sources;
    archive_name_format = "ferrix-{now:%Y-%m-%dT%H:%M:%S.%f}";
    compression = "zstd,3";
    one_file_system = true;
    local_path = lib.getExe pkgs.borgbackup;
    retries = 2;
    retry_wait = 60;
    lock_wait = 600;
    # Do not record a successful backup when Borg reports unreadable files.
    borg_exit_codes = map (code: {
      inherit code;
      treat_as = "error";
    }) ([ 1 ] ++ lib.range 100 127);
    exclude_patterns = [
      "sh:home/mpfammatter/.cache"
      "sh:home/mpfammatter/.local/share/Trash"
      "sh:var/lib/inigo/.hermes/cache"
      "sh:var/lib/inigo/.cache"
      "sh:**/node_modules"

      "sh:var/lib/docker/volumes/zulip_zulip/_data/backups"
    ]
    ++ lib.concatMap (
      root:
      map (suffix: "sh:${lib.removePrefix "/" root}/**/${suffix}") [
        "*.db"
        "*.db-*"
        "*.sqlite"
        "*.sqlite-*"
        "*.sqlite3"
        "*.sqlite3-*"
      ]
    ) databaseRoots;
  }
  // policy.retention;
  runBackup =
    destination:
    pkgs.writeShellScript "ferrix-backup-${destination}" ''
      set -euo pipefail
      test -s ${policy.knownHostsFile}
      ${pkgs.openssh}/bin/ssh-keygen -F ${hosts.${destination}} \
        -f ${policy.knownHostsFile} >/dev/null
      ${lib.concatMapStringsSep "\n" (path: "test -d ${lib.escapeShellArg path}") (lib.take 5 sources)}
      ${pkgs.python3}/bin/python3 ${./backup-state.py} \
        --destination ${stateDirectory}/sqlite \
        --exclude /var/lib/inigo/.hermes/cache \
        --zulip-compose /etc/zulip/compose.yaml \
        ${lib.escapeShellArgs databaseRoots}
      ${pkgs.borgmatic}/bin/borgmatic --config /etc/borgmatic.d/${destination}.yaml create --stats
      ${health} record ${destination}
    '';
  destinations = builtins.attrNames policy.repositories;
in
{
  imports = [ ../modules/ferrix-backup-alerts.nix ];

  sops.secrets =
    lib.genAttrs
      (map (name: "ferrix-backup/${name}") [
        "hoth-passphrase"
        "borgbase-passphrase"
        "hoth-ssh-key"
        "borgbase-ssh-key"
      ])
      (name: {
        sopsFile = ../../secrets/ferrix-backups.yaml;
        key = lib.removePrefix "ferrix-backup/" name;
        owner = "root";
        group = "root";
        mode = "0400";
      });

  environment.systemPackages = map borgWrapper destinations;
  environment.etc = {
    "ferrix-backup-recovery/credentials.sops.yaml" = {
      source = ../../secrets/ferrix-backups.yaml;
      # Copy actual files: Borg deliberately does not follow store symlinks.
      mode = "0400";
    };
    "ferrix-backup-recovery/policy.json" = {
      text = builtins.toJSON policy;
      mode = "0400";
    };
  };

  services.borgmatic = {
    enable = true;
    enableConfigCheck = true;
    configurations = lib.genAttrs destinations (
      destination:
      commonSettings
      // {
        repositories = [
          {
            path = policy.repositories.${destination};
            label = destination;
          }
        ];
        encryption_passcommand = "${pkgs.coreutils}/bin/cat ${secret "${destination}-passphrase"}";
        ssh_command = sshCommand destination;
      }
    );
  };

  systemd.tmpfiles.rules = [
    "d /var/cache/ferrix-backup 0700 root root -"
    "d ${stateDirectory}/security 0700 root root -"
    "d ${stateDirectory}/keys 0700 root root -"
  ];

  systemd.services =
    lib.genAttrs (map (destination: "ferrix-backup-${destination}") destinations) (
      name:
      let
        destination = lib.removePrefix "ferrix-backup-" name;
      in
      {
        description = "Back up Ferrix to ${destination}";
        after = [
          "network-online.target"
          "docker.service"
          "zulip.service"
        ];
        wants = [ "network-online.target" ];
        requires = [
          "docker.service"
          "zulip.service"
        ];
        onFailure = [ "ferrix-backup-alert@${name}.service" ];
        path = [
          pkgs.docker
          pkgs.coreutils
        ];
        environment = borgEnvironment destination;
        unitConfig = {
          StartLimitIntervalSec = "1d";
          StartLimitBurst = 3;
        };
        serviceConfig = {
          Type = "oneshot";
          # Separate units still serialize preparation and cache use; a failed
          # Hoth run cannot stop the independently scheduled BorgBase unit.
          ExecStart = "${pkgs.util-linux}/bin/flock -w 86400 ${stateDirectory}/job.lock ${runBackup destination}";
          User = "root";
          UMask = "0077";
          Nice = 15;
          IOSchedulingClass = "idle";
          TimeoutStartSec = "2d";
          Restart = "on-failure";
          RestartSec = "30min";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = "read-only";
          ProtectSystem = "strict";
          ReadWritePaths = [
            stateDirectory
            "/var/cache/ferrix-backup"
            "/var/lib/docker/volumes/zulip_zulip/_data/backups"
          ]
          ++ databaseRoots;
        };
      }
    )
    // {
      # The upstream service would also prune and compact. Append-only clients
      # instead have independent create-only units and separate trusted upkeep.
      borgmatic.enable = false;
      ferrix-backup-freshness = {
        description = "Check Ferrix's local backup success records";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        onFailure = [ "ferrix-backup-alert@ferrix-backup-freshness.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          UMask = "0077";
        };
        script = lib.concatMapStringsSep "\n" (
          destination: "${health} check-local ${destination}"
        ) destinations;
      };
    };

  systemd.timers =
    lib.genAttrs (map (destination: "ferrix-backup-${destination}") destinations) (name: {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = if name == "ferrix-backup-hoth" then "*-*-* 02:00:00" else "*-*-* 03:00:00";
        RandomizedDelaySec = "10min";
        Persistent = true;
      };
    })
    // {
      borgmatic.enable = false;
      ferrix-backup-freshness = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30min";
          OnUnitActiveSec = "1h";
        };
      };
    };
}
