{
  pkgs,
  ferrix,
  hoth,
}:

assert ferrix.services.managedBackups.enable;
assert hoth.services.managedBackups.enable;
assert !ferrix.systemd.services.borgmatic.enable;
assert !hoth.systemd.services.borgmatic.enable;
assert !ferrix.systemd.timers.borgmatic.enable;
assert !hoth.systemd.timers.borgmatic.enable;
assert builtins.length (builtins.attrNames ferrix.services.borgmatic.configurations) == 2;
assert builtins.length (builtins.attrNames hoth.services.borgmatic.configurations) == 2;
assert !(ferrix.sops.secrets ? "ferrix-backup/borgbase-maintenance-ssh-key");
assert hoth.services.borgbackup.repos.ferrix.path == "/mnt/backup2/borg/ferrix";
assert hoth.services.borgbackup.repos.ferrix.authorizedKeys == [ ];
assert hoth.services.borgbackup.repos.ferrix.authorizedKeysAppendOnly != [ ];
assert ferrix.environment.etc."ferrix-backup-recovery/credentials.sops.yaml".mode == "0400";
assert hoth.systemd.timers.backup-maintain-hoth-local.wantedBy == [ ];
assert hoth.systemd.timers.backup-maintain-ferrix-hoth.wantedBy == [ ];
assert pkgs.lib.hasInfix "/locks/repository-hoth-local.lock"
  hoth.systemd.services.backup-maintain-hoth-local.serviceConfig.ExecStart;
assert pkgs.lib.hasInfix "/locks/repository-hoth-local.lock"
  hoth.systemd.services.backup-verify-hoth-local.serviceConfig.ExecStart;
assert builtins.elem "/mnt/backup1/backups/afp-northwestern"
  hoth.services.managedBackups.jobs.hoth.paths;
assert
  !(builtins.elem "/mnt/backup2/backups/afp-northwestern" hoth.services.managedBackups.jobs.hoth.paths);
assert
  !(pkgs.lib.any (pkgs.lib.hasInfix "photoprism") hoth.services.managedBackups.jobs.hoth.paths);

pkgs.runCommand "managed-backup-check"
  {
    HOTH_BACKUP_EXCLUDES = builtins.toJSON hoth.services.borgmatic.configurations.managed-hoth-local.exclude_patterns;
    FERRIX_TEST_EXCLUDES = builtins.toJSON ferrix.services.borgmatic.configurations.managed-ferrix-hoth.exclude_patterns;
    nativeBuildInputs = [
      pkgs.python3
      pkgs.borgbackup
      pkgs.borgmatic
      pkgs.util-linux
      pkgs.openssh
    ];
  }
  ''
    export TMPDIR="$PWD/tmp"
    export HOME="$PWD/home"
    mkdir -p "$TMPDIR" "$HOME"
    python3 ${ferrix.system.build.managedBackupRuntime}/runner.py --help >/dev/null
    cp ${./backups}/*.py .
    python3 -W error::ResourceWarning -m unittest discover -p '*_test.py' -v
    cp ${../hoth/backup-applications.py} backup-applications.py
    cp ${../hoth/backup-applications_test.py} backup-applications_test.py
    python3 -W error::ResourceWarning -m unittest -v backup-applications_test.py
    cp ${../ferrix/backup-state.py} backup-state.py
    cp ${../ferrix/backup-state_test.py} backup-state_test.py
    python3 -W error::ResourceWarning -m unittest -v backup-state_test.py
    if ${hoth.system.build.managedBackupMountGuards.ferrix-hoth} >guard.stdout 2>guard.stderr; then
      echo "Mount guard accepted a missing backup disk" >&2
      exit 1
    fi
    python3 -c 'from pathlib import Path; assert "refusing repository access" in Path("guard.stderr").read_text()'
    touch "$out"
  ''
