let
  publicKeys = builtins.fromJSON (builtins.readFile ./ferrix-backup-public-keys.json);
in
{
  inherit publicKeys;
  diskUUID = "f8c69028-4b3f-4f4a-9f10-c064aaede45c";
  localRepository = "/mnt/backup2/borg/ferrix";
  knownHostsFile = "/var/lib/ferrix-backup/ssh_known_hosts";
  repositories = {
    hoth = "ssh://ferrix-borg@hoth.tailbb897.ts.net/./.";
    borgbase = "ssh://hlek3m3n@hlek3m3n.repo.borgbase.com/./repo";
  };
  retention = {
    keep_daily = 7;
    keep_weekly = 4;
    keep_monthly = 12;
    keep_yearly = 2;
  };
}
