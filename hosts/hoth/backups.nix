{
  config,
  lib,
  pkgs,
  ...
}:

let
  policy = import ../modules/ferrix-backup-policy.nix;
  immichVolume = "4e5d855e02e90178383e8ccb1495a04c9276c8660f890bb777824af98fcfd315";
  prepare = pkgs.writeShellScript "prepare-hoth-backup" ''
    set -euo pipefail
    exec ${pkgs.python3}/bin/python3 ${./backup-applications.py}
  '';
  frigate = "/home/mpfammatter/docker/frigate";
in
{
  imports = [
    ../modules/backup-ssh-trust.nix
    ../modules/backups.nix
  ];

  sops.secrets."backup/email-username" = {
    key = "zulip/email_username";
    sopsFile = ../../secrets/backup-shared.yaml;
  };
  sops.secrets."backup/email-password" = {
    key = "zulip/email_password";
    sopsFile = ../../secrets/backup-shared.yaml;
  };

  services.managedBackups = {
    enable = true;
    notifications = {
      usernameFile = config.sops.secrets."backup/email-username".path;
      passwordFile = config.sops.secrets."backup/email-password".path;
    };
    repositories = {
      hoth-local = {
        sourceId = "hoth";
        url = "/mnt/backup2/borg/endor";
        passphraseFile = config.sops.secrets."borg/borg_passphrase".path;
        requiredMounts."/mnt/backup2" = policy.diskUUID;
        monitor = true;
        maintenance = true;
      };
      hoth-borgbase = {
        sourceId = "hoth";
        url = "ssh://x387mg6b@x387mg6b.repo.borgbase.com/./repo";
        passphraseFile = config.sops.secrets."borg/borg_passphrase".path;
        sshHostname = "x387mg6b.repo.borgbase.com";
        sshKeyFile = "/var/lib/managed-backups/identities/hoth-borgbase";
        generateSSHKey = true;
        knownHostsFile = policy.knownHostsFile;
        monitor = true;
        maintenance = true;
      };
    };
    jobs.hoth = {
      sourceId = "hoth";
      paths = [
        "/home/mpfammatter"
        "/mnt/backup2/homeassistant"
        "/mnt/backup1/backups/dad"
        "/mnt/backup1/backups/afp-northwestern"
        "/mnt/backup1/immich"
        "/var/lib/docker/volumes/${immichVolume}/_data"
      ];
      requiredMounts = {
        "/mnt/backup1" = "4ce63432-8223-495e-95a0-8aac69181517";
        "/mnt/backup2" = policy.diskUUID;
      };
      sqliteRoots = [ frigate ];
      sqliteExcludedDirectories = [ "${frigate}/media" ];
      # Fail closed on a custom DB layout rather than silently omitting it.
      requiredSqliteFiles = [ "${frigate}/frigate.db" ];
      prepareCommand = "${prepare}";
      requiredServices = [ "docker.service" ];
      readWritePaths = [ frigate ];
      excludes = [
        "sh:home/mpfammatter/.cache"
        "sh:home/mpfammatter/.local/share/Trash"
        "sh:**/node_modules"
        "sh:home/mpfammatter/docker/immich-db"
      ]
      ++ map (suffix: "sh:${lib.removePrefix "/" frigate}/**/${suffix}") [
        "*.db"
        "*.db-*"
        "*.sqlite"
        "*.sqlite-*"
        "*.sqlite3"
        "*.sqlite3-*"
      ];
      # Preserve existing whole-home coverage, including Frigate media. Reducing
      # footage coverage requires an explicit policy decision, not this migration.
      destinations = {
        local = {
          repository = "hoth-local";
          schedule = "*-*-* 00:30:00";
        };
        borgbase = {
          repository = "hoth-borgbase";
          schedule = "*-*-* 01:30:00";
        };
      };
    };
  };
}
