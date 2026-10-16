{
  config,
  lib,
  pkgs,
  ...
}:

let
  policy = import ../modules/ferrix-backup-policy.nix;
  secret = name: config.sops.secrets."ferrix-backup/${name}".path;
in
{
  imports = [ ../modules/backups.nix ];

  sops.secrets =
    lib.genAttrs
      (map (name: "ferrix-backup/${name}") [
        "hoth-passphrase"
        "borgbase-passphrase"
      ])
      (name: {
        sopsFile = ../../secrets/ferrix-backups.yaml;
        key = lib.removePrefix "ferrix-backup/" name;
        owner = "root";
        group = "root";
        mode = "0400";
      });
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "ferrix-backup-health" ''
      exec /run/current-system/sw/bin/backup-health "$@"
    '')
  ];

  services.managedBackups.repositories = {
    ferrix-hoth = {
      sourceId = "ferrix";
      url = policy.localRepository;
      passphraseFile = secret "hoth-passphrase";
      localUser = "ferrix-borg";
      requiredMounts."/mnt/backup2" = policy.diskUUID;
      wrapperAliases = [ "ferrix-borg-hoth" ];
      receiver = {
        enable = true;
        name = "ferrix";
        appendOnlyKeys = [ policy.publicKeys.hoth ];
      };
      monitor = true;
      maintenance = true;
    };
    ferrix-borgbase = {
      sourceId = "ferrix";
      url = policy.repositories.borgbase;
      passphraseFile = secret "borgbase-passphrase";
      # Keep the existing Hoth-only private key; never share it through SOPS.
      sshKeyFile = "/var/lib/ferrix-backup/borgbase-maintenance-ssh-key";
      generateSSHKey = true;
      sshHostname = "hlek3m3n.repo.borgbase.com";
      knownHostsFile = policy.knownHostsFile;
      wrapperAliases = [ "ferrix-borg-borgbase" ];
      monitor = true;
      maintenance = true;
    };
  };
  system.build.ferrixBackupMountGuard = config.system.build.managedBackupMountGuards.ferrix-hoth;
  systemd.services.backup-key-ferrix-borgbase.aliases = [ "ferrix-backup-maintenance-key.service" ];
  systemd.services.backup-maintain-ferrix-hoth.aliases = [ "ferrix-backup-maintain-hoth.service" ];
  systemd.services.backup-maintain-ferrix-borgbase.aliases = [
    "ferrix-backup-maintain-borgbase.service"
  ];
  systemd.services.backup-verify-ferrix-hoth.aliases = [ "ferrix-backup-verify-hoth.service" ];
  systemd.services.backup-verify-ferrix-borgbase.aliases = [
    "ferrix-backup-verify-borgbase.service"
  ];
  systemd.services.backup-monitor-ferrix-hoth.aliases = [ "ferrix-backup-monitor-hoth.service" ];
  systemd.services.backup-monitor-ferrix-borgbase.aliases = [
    "ferrix-backup-monitor-borgbase.service"
  ];
}
