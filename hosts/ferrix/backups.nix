{
  config,
  lib,
  pkgs,
  ...
}:

let
  policy = import ../modules/ferrix-backup-policy.nix;
  secret = name: config.sops.secrets."ferrix-backup/${name}".path;
  databaseRoots = [
    "/var/lib/inigo/.hermes"
    "/var/lib/private/silverbullet"
    "/var/lib/remote-pi-relay"
  ];
  prepare = pkgs.writeShellScript "prepare-ferrix-backup" ''
    set -euo pipefail
    exec ${pkgs.python3}/bin/python3 ${./prepare-backup.py} ${./backup-state.py}
  '';
in
{
  imports = [ ../modules/backups.nix ];

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
      })
    // {
      "backup/email-username".key = "zulip/email_username";
      "backup/email-password".key = "zulip/email_password";
    };

  environment.etc = {
    "ferrix-backup-recovery/credentials.sops.yaml" = {
      source = ../../secrets/ferrix-backups.yaml;
      mode = "0400";
    };
    "ferrix-backup-recovery/policy.json" = {
      text = builtins.toJSON policy;
      mode = "0400";
    };
  };
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "ferrix-backup-health" ''
      exec /run/current-system/sw/bin/backup-health "$@"
    '')
  ];

  services.managedBackups = {
    enable = true;
    notifications = {
      usernameFile = config.sops.secrets."backup/email-username".path;
      passwordFile = config.sops.secrets."backup/email-password".path;
    };
    repositories = lib.genAttrs [ "ferrix-hoth" "ferrix-borgbase" ] (
      name:
      let
        destination = lib.removePrefix "ferrix-" name;
      in
      {
        sourceId = "ferrix";
        url = policy.repositories.${destination};
        passphraseFile = secret "${destination}-passphrase";
        sshKeyFile = secret "${destination}-ssh-key";
        sshHostname =
          if destination == "hoth" then "hoth.tailbb897.ts.net" else "hlek3m3n.repo.borgbase.com";
        knownHostsFile = policy.knownHostsFile;
        wrapperAliases = [ "ferrix-borg-${destination}" ];
      }
    );
    jobs.ferrix = {
      sourceId = "ferrix";
      paths = [
        "/home/mpfammatter"
        "/var/lib/inigo"
        "/var/lib/private/silverbullet"
        "/var/lib/remote-pi-relay"
        "/var/lib/docker/volumes/zulip_zulip/_data"
        "/etc/ferrix-backup-recovery"
      ];
      requiredMounts."/" = lib.removePrefix "/dev/disk/by-uuid/" config.fileSystems."/".device;
      sqliteRoots = databaseRoots;
      sqliteExcludedDirectories = [ "/var/lib/inigo/.hermes/cache" ];
      prepareCommand = "${prepare}";
      requiredServices = [
        "docker.service"
        "zulip.service"
      ];
      readWritePaths = databaseRoots ++ [ "/var/lib/docker/volumes/zulip_zulip/_data/backups" ];
      excludes = [
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
      destinations = {
        hoth = {
          repository = "ferrix-hoth";
          schedule = "*-*-* 02:00:00";
        };
        borgbase = {
          repository = "ferrix-borgbase";
          schedule = "*-*-* 03:00:00";
        };
      };
    };
  };
  # Preserve operator service names, not their old timers or shared upload lock.
  systemd.services.backup-ferrix-hoth.aliases = [ "ferrix-backup-hoth.service" ];
  systemd.services.backup-ferrix-borgbase.aliases = [ "ferrix-backup-borgbase.service" ];
}
