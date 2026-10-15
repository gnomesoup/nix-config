{
  pkgs,
  ferrix,
  hoth,
}:

assert ferrix.services.borgmatic.enable;
assert
  builtins.attrNames ferrix.services.borgmatic.configurations == [
    "borgbase"
    "hoth"
  ];
assert !ferrix.systemd.timers.borgmatic.enable;
assert ferrix.systemd.timers.ferrix-backup-hoth.timerConfig.Persistent;
assert ferrix.systemd.timers.ferrix-backup-borgbase.timerConfig.Persistent;
assert !(ferrix.sops.secrets ? "ferrix-backup/borgbase-maintenance-ssh-key");
assert ferrix.environment.etc."ferrix-backup-recovery/credentials.sops.yaml".mode == "0400";
assert hoth.systemd.services.ferrix-backup-maintenance-key.serviceConfig.User == "root";
assert hoth.services.borgbackup.repos.ferrix.path == "/mnt/backup2/borg/ferrix";
assert hoth.services.borgbackup.repos.ferrix.authorizedKeys == [ ];
assert hoth.services.borgbackup.repos.ferrix.authorizedKeysAppendOnly != [ ];
assert
  hoth.systemd.services.borgbackup-repo-ferrix.unitConfig.RequiresMountsFor == [ "/mnt/backup2" ];
assert hoth.systemd.timers.ferrix-backup-monitor-hoth.timerConfig.Persistent;
assert hoth.systemd.timers.ferrix-backup-monitor-borgbase.timerConfig.Persistent;

pkgs.runCommand "ferrix-backup-check"
  {
    FERRIX_TEST_EXCLUDES = builtins.toJSON ferrix.services.borgmatic.configurations.hoth.exclude_patterns;
    nativeBuildInputs = [
      pkgs.borgbackup
      pkgs.borgmatic
      pkgs.python3
    ];
  }
  ''
    export TMPDIR="$PWD/tmp"
    export HOME="$PWD/home"
    mkdir -p "$TMPDIR" "$HOME"
    cp ${../ferrix/backup-state.py} backup-state.py
    cp ${../ferrix/backup-state_test.py} backup-state_test.py
    cp ${./ferrix-backup-health.py} ferrix-backup-health.py
    cp ${./ferrix-backup-health_test.py} ferrix-backup-health_test.py
    python3 -W error::ResourceWarning -m unittest -v backup-state_test.py ferrix-backup-health_test.py
    if ${hoth.system.build.ferrixBackupMountGuard} >guard.stdout 2>guard.stderr; then
      echo "Mount guard unexpectedly accepted a missing backup disk" >&2
      exit 1
    fi
    python3 -c 'from pathlib import Path; assert "refusing repository access" in Path("guard.stderr").read_text()'
    touch "$out"
  ''
