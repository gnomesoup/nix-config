{
  config,
  lib,
  pkgs,
  ...
}:

let
  policy = import ../modules/ferrix-backup-policy.nix;
  secret = name: config.sops.secrets."ferrix-backup/${name}".path;
  health = lib.getExe config.system.build.ferrixBackupHealth;
  maintenanceKey = "/var/lib/ferrix-backup/borgbase-maintenance-ssh-key";
  mountGuard = pkgs.writeShellScript "ferrix-backup-mount-guard" ''
    set -euo pipefail
    uuid="$(${pkgs.util-linux}/bin/findmnt --noheadings --output UUID --mountpoint /mnt/backup2 || true)"
    if [ "$uuid" != ${lib.escapeShellArg policy.diskUUID} ]; then
      echo "The expected backup2 filesystem is not mounted; refusing repository access." >&2
      exit 1
    fi
  '';
  serve = pkgs.writeShellScript "ferrix-borg-serve" ''
    set -euo pipefail
    ${mountGuard}
    cd ${policy.localRepository}
    exec ${pkgs.borgbackup}/bin/borg serve --append-only --restrict-to-repository .
  '';
  remoteSSH = lib.concatStringsSep " " [
    "${pkgs.openssh}/bin/ssh"
    "-i ${maintenanceKey}"
    "-o BatchMode=yes"
    "-o IdentitiesOnly=yes"
    "-o StrictHostKeyChecking=yes"
    "-o UserKnownHostsFile=${policy.knownHostsFile}"
    "-o GlobalKnownHostsFile=/dev/null"
    "-o ConnectTimeout=30"
    "-o ServerAliveInterval=30"
    "-o ServerAliveCountMax=3"
  ];
  localBorg = pkgs.writeShellScriptBin "ferrix-borg-hoth" ''
    set -euo pipefail
    ${mountGuard}
    export BORG_REPO=${policy.localRepository}
    # Drop privileges before touching repository files so compaction never
    # leaves root-owned segments that the restricted SSH account cannot read.
    export BORG_PASSPHRASE="$(${pkgs.coreutils}/bin/cat ${secret "hoth-passphrase"})"
    unset BORG_PASSCOMMAND
    export BORG_CACHE_DIR=/var/cache/ferrix-borg
    export BORG_SECURITY_DIR=/var/lib/ferrix-borg/security
    export BORG_KEYS_DIR=/var/lib/ferrix-borg/keys
    exec ${pkgs.util-linux}/bin/runuser --preserve-environment -u ferrix-borg -- \
      ${pkgs.borgbackup}/bin/borg --lock-wait 600 "$@"
  '';
  remoteBorg = pkgs.writeShellScriptBin "ferrix-borg-borgbase" ''
    set -euo pipefail
    test -s ${maintenanceKey}
    test -s ${policy.knownHostsFile}
    ${pkgs.openssh}/bin/ssh-keygen -F hlek3m3n.repo.borgbase.com -f ${policy.knownHostsFile} >/dev/null
    export BORG_REPO=${lib.escapeShellArg policy.repositories.borgbase}
    export BORG_RSH=${lib.escapeShellArg remoteSSH}
    export BORG_PASSCOMMAND=${lib.escapeShellArg "${pkgs.coreutils}/bin/cat ${secret "borgbase-passphrase"}"}
    export BORG_CACHE_DIR=/var/cache/ferrix-backup/borgbase
    export BORG_SECURITY_DIR=/var/lib/ferrix-backup/security/borgbase
    export BORG_KEYS_DIR=/var/lib/ferrix-backup/keys/borgbase
    exec ${pkgs.borgbackup}/bin/borg --lock-wait 600 "$@"
  '';
  wrappers = {
    hoth = localBorg;
    borgbase = remoteBorg;
  };
  borg = destination: "${wrappers.${destination}}/bin/ferrix-borg-${destination}";
  retentionArgs = lib.concatStringsSep " " (
    lib.mapAttrsToList (
      name: value: "--${lib.replaceStrings [ "_" ] [ "-" ] name} ${toString value}"
    ) policy.retention
  );
  destinations = builtins.attrNames wrappers;
  maintenance =
    destination:
    pkgs.writeShellScript "ferrix-backup-maintain-${destination}" ''
      set -euo pipefail
      FERRIX_BORG_COMMAND=${borg destination} ${health} require-fresh ${destination}
      # Check before destructive maintenance, and scope retention to this host.
      ${borg destination} check --repository-only
      ${borg destination} prune --glob-archives 'ferrix-*' ${retentionArgs}
      ${borg destination} compact
      ${borg destination} check --archives-only --glob-archives 'ferrix-*' --last 1
    '';
  serviceBase = name: {
    after = [
      "network-online.target"
    ]
    ++ lib.optional (lib.hasSuffix "-borgbase" name) "ferrix-backup-maintenance-key.service";
    wants = [ "network-online.target" ];
    requires = lib.optional (lib.hasSuffix "-borgbase" name) "ferrix-backup-maintenance-key.service";
    onFailure = [ "ferrix-backup-alert@${name}.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      UMask = "0077";
      Nice = 15;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "2d";
    };
  };
in
{
  imports = [ ../modules/ferrix-backup-alerts.nix ];

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

  services.borgbackup.repos.ferrix = {
    path = policy.localRepository;
    user = "ferrix-borg";
    group = "ferrix-borg";
    allowSubRepos = false;
    authorizedKeysAppendOnly = [ policy.publicKeys.hoth ];
  };

  # The native forced command does not check the nofail disk. Replace only
  # this account's generated key restriction with the mount-guarded equivalent.
  users.users.ferrix-borg.openssh.authorizedKeys.keys = lib.mkForce [
    ''command="${serve}",restrict ${policy.publicKeys.hoth}''
  ];

  environment.systemPackages = [
    localBorg
    remoteBorg
  ];
  system.build.ferrixBackupMountGuard = mountGuard;
  systemd.tmpfiles.rules = [
    "d /var/lib/ferrix-borg 0700 ferrix-borg ferrix-borg -"
    "d /var/cache/ferrix-borg 0700 ferrix-borg ferrix-borg -"
    "d /var/cache/ferrix-backup 0700 root root -"
    "d /var/lib/ferrix-backup/security 0700 root root -"
    "d /var/lib/ferrix-backup/keys 0700 root root -"
  ];

  systemd.services = {
    ferrix-backup-maintenance-key = {
      description = "Provision Hoth's private BorgBase maintenance identity";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        UMask = "0077";
        StateDirectory = "ferrix-backup";
        StateDirectoryMode = "0700";
      };
      # This key must never enter the shared SOPS bundle: Ferrix can decrypt
      # that bundle, which would defeat the append-only client restriction.
      script = ''
        set -euo pipefail
        if [ ! -e ${maintenanceKey} ]; then
          temporary="$(${pkgs.coreutils}/bin/mktemp -d /var/lib/ferrix-backup/.maintenance-key.XXXXXX)"
          trap '${pkgs.coreutils}/bin/rm -rf "$temporary"' EXIT
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
            -C ferrix-backup-borgbase-maintenance -f "$temporary/key"
          ${pkgs.coreutils}/bin/mv "$temporary/key" ${maintenanceKey}
        fi
        ${pkgs.coreutils}/bin/chmod 0400 ${maintenanceKey}
        ${pkgs.openssh}/bin/ssh-keygen -y -f ${maintenanceKey} > ${maintenanceKey}.pub
        ${pkgs.coreutils}/bin/chmod 0644 ${maintenanceKey}.pub
      '';
    };
    borgbackup-repo-ferrix = {
      unitConfig.RequiresMountsFor = [ "/mnt/backup2" ];
      serviceConfig.UMask = "0077";
      preStart = ''
        ${mountGuard}
        ${pkgs.coreutils}/bin/install -d -m 0711 -o root -g root /mnt/backup2/borg
      '';
      postStart = "${pkgs.coreutils}/bin/chmod 0700 ${policy.localRepository}";
    };
  }
  // lib.genAttrs (map (destination: "ferrix-backup-maintain-${destination}") destinations) (
    name:
    let
      destination = lib.removePrefix "ferrix-backup-maintain-" name;
    in
    lib.recursiveUpdate (serviceBase name) {
      description = "Prune, compact, and check Ferrix's ${destination} repository";
      serviceConfig.ExecStart = "${pkgs.util-linux}/bin/flock -w 86400 /var/lib/ferrix-backup/maintenance-${destination}.lock ${maintenance destination}";
    }
  )
  // lib.genAttrs (map (destination: "ferrix-backup-verify-${destination}") destinations) (
    name:
    let
      destination = lib.removePrefix "ferrix-backup-verify-" name;
    in
    lib.recursiveUpdate (serviceBase name) {
      description = "Verify all archived data in Ferrix's ${destination} repository";
      script = "${borg destination} check --verify-data --glob-archives 'ferrix-*'";
    }
  )
  // lib.genAttrs (map (destination: "ferrix-backup-monitor-${destination}") destinations) (
    name:
    let
      destination = lib.removePrefix "ferrix-backup-monitor-" name;
    in
    lib.recursiveUpdate (serviceBase name) {
      description = "Independently check Ferrix's ${destination} backup freshness";
      environment.FERRIX_BORG_COMMAND = borg destination;
      serviceConfig.TimeoutStartSec = "20min";
      script = "${health} check-repository ${destination}";
    }
  );

  systemd.timers =
    lib.genAttrs (map (destination: "ferrix-backup-maintain-${destination}") destinations) (_: {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 06:00:00";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    })
    // lib.genAttrs (map (destination: "ferrix-backup-verify-${destination}") destinations) (_: {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-01..07 12:00:00";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    })
    // lib.genAttrs (map (destination: "ferrix-backup-monitor-${destination}") destinations) (_: {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 10:00:00";
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    });
}
