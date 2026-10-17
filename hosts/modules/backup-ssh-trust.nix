{ ... }:

{
  # Public keys are pinned in source; activation needs no network trust bootstrap.
  environment.etc."managed-backups/ssh_known_hosts" = {
    source = ./backup-ssh-known-hosts;
    mode = "0444";
  };
}
