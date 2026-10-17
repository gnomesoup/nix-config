{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.managedBackups;
  inherit (lib) mkOption types;
  str =
    default: description:
    mkOption {
      type = types.str;
      inherit default description;
    };
  strings =
    description:
    mkOption {
      type = types.listOf types.str;
      default = [ ];
      inherit description;
    };
  flag =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };
  number =
    default: description:
    mkOption {
      type = types.ints.positive;
      inherit default description;
    };
  optionalString =
    description:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit description;
    };
  mounts = mkOption {
    type = types.attrsOf types.str;
    default = { };
    description = "Required mountpoints mapped to their expected filesystem UUIDs.";
  };
  state = cfg.stateDirectory;
  runtime = pkgs.runCommand "managed-backup-runtime" { } ''
    mkdir -p "$out"
    cp ${./backups/runner.py} "$out/runner.py"
    cp ${./backups/sqlite_snapshot.py} "$out/sqlite_snapshot.py"
    cp ${./backups/health.py} "$out/health.py"
  '';
  repos = cfg.repositories;
  enabledRepos = lib.filterAttrs (_: r: r.monitor || r.maintenance) repos;
  receiverRepos = lib.filterAttrs (_: r: r.receiver.enable) repos;
  entries = lib.concatLists (
    lib.mapAttrsToList (
      jobName: job:
      lib.mapAttrsToList (destination: target: {
        id = "${jobName}-${destination}";
        inherit
          jobName
          job
          destination
          target
          ;
        repo = repos.${target.repository};
      }) job.destinations
    ) cfg.jobs
  );
  entryAttrs = builtins.listToAttrs (map (entry: lib.nameValuePair entry.id entry) entries);
  requiredMounts = values: lib.mapAttrsToList (path: uuid: { inherit path uuid; }) values;
  guard =
    name:
    pkgs.writeShellScript "backup-mount-guard-${name}" ''
      set -euo pipefail
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (path: uuid: ''
          actual="$(${pkgs.util-linux}/bin/findmnt --noheadings --output UUID --mountpoint ${lib.escapeShellArg path} || true)"
          if [ "$actual" != ${lib.escapeShellArg uuid} ]; then
            echo 'Expected backup filesystem is not mounted; refusing repository access.' >&2
            exit 1
          fi
        '') repos.${name}.requiredMounts
      )}
    '';
  sshCommand =
    r:
    lib.escapeShellArgs [
      "${pkgs.openssh}/bin/ssh"
      "-i"
      r.sshKeyFile
      "-o"
      "BatchMode=yes"
      "-o"
      "IdentitiesOnly=yes"
      "-o"
      "StrictHostKeyChecking=yes"
      "-o"
      "UserKnownHostsFile=${r.knownHostsFile}"
      "-o"
      "GlobalKnownHostsFile=/dev/null"
      "-o"
      "ConnectTimeout=30"
      "-o"
      "ServerAliveInterval=30"
      "-o"
      "ServerAliveCountMax=3"
    ];
  repoState =
    name:
    if repos.${name}.localUser == "root" then
      "${state}/repositories/${name}"
    else
      "/var/lib/backup-repository-${name}";
  repoCache =
    name:
    if repos.${name}.localUser == "root" then
      "/var/cache/managed-backups/${name}"
    else
      "/var/cache/backup-repository-${name}";
  borgEnvironment =
    name:
    let
      r = repos.${name};
    in
    {
      BORG_REPO = r.url;
      BORG_PASSCOMMAND = "${pkgs.coreutils}/bin/cat ${lib.escapeShellArg r.passphraseFile}";
      BORG_CACHE_DIR = repoCache name;
      BORG_SECURITY_DIR = "${repoState name}/security";
      BORG_KEYS_DIR = "${repoState name}/keys";
    }
    // lib.optionalAttrs (r.sshHostname != null) { BORG_RSH = sshCommand r; };
  wrappers = lib.mapAttrs (
    name: r:
    pkgs.writeShellScriptBin "backup-borg-${name}" ''
      set -euo pipefail
      umask 077
      fail() {
        printf 'Backup preflight (%s): %s\n' ${lib.escapeShellArg name} "$1" >&2
        exit 1
      }
      require_file() {
        if [ ! -s "$1" ]; then
          fail "$2 is missing or empty"
        fi
      }
      ${guard name}
      require_file ${lib.escapeShellArg r.passphraseFile} 'Repository passphrase file'
      ${lib.optionalString (r.sshHostname != null) ''
        require_file ${lib.escapeShellArg r.sshKeyFile} 'SSH identity file'
        require_file ${lib.escapeShellArg r.knownHostsFile} 'Verified SSH trust file'
        if ! ${pkgs.openssh}/bin/ssh-keygen -F ${lib.escapeShellArg r.sshHostname} \
          -f ${lib.escapeShellArg r.knownHostsFile} >/dev/null; then
          fail 'Verified SSH host key is missing'
        fi
      ''}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}") (borgEnvironment name)
      )}
      ${lib.optionalString (r.localUser != "root") ''
        export BORG_PASSPHRASE="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg r.passphraseFile})"
        unset BORG_PASSCOMMAND
      ''}
      exec ${
        lib.optionalString (
          r.localUser != "root"
        ) "${pkgs.util-linux}/bin/runuser --preserve-environment -u ${lib.escapeShellArg r.localUser} -- "
      }${pkgs.borgbackup}/bin/borg --lock-wait 600 "$@"
    ''
  ) repos;
  borg = name: "${wrappers.${name}}/bin/backup-borg-${name}";
  smtp = cfg.notifications;
  notificationSettings = {
    alert_directory = "${state}/alerts";
    smtp = {
      inherit (smtp) host port recipient;
      username_file = smtp.usernameFile;
      password_file = smtp.passwordFile;
    };
  };
  notificationConfig = pkgs.writeText "backup-notifications.json" (
    builtins.toJSON notificationSettings
  );
  healthProgram = pkgs.writeShellScriptBin "backup-health" ''
    exec ${pkgs.python3}/bin/python3 ${runtime}/health.py --config ${notificationConfig} "$@"
  '';
  repoHealthConfig =
    name:
    pkgs.writeText "backup-health-${name}.json" (
      builtins.toJSON (
        notificationSettings
        // {
          source_id = repos.${name}.sourceId;
          repository_id = name;
          archive_prefix = "${repos.${name}.sourceId}-complete-";
          borg_command = [ (borg name) ];
          max_age_seconds = cfg.maxAgeSeconds;
        }
      )
    );
  health =
    name: action:
    "${pkgs.python3}/bin/python3 ${runtime}/health.py --config ${repoHealthConfig name} ${action}";
  keyServices = name: lib.optional repos.${name}.generateSSHKey "backup-key-${name}.service";
  baseService = name: {
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ]
    ++ keyServices name;
    wants = [ "network-online.target" ];
    requires = keyServices name;
    onFailure = [ "backup-alert@${name}.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      UMask = "0077";
      Nice = 15;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "2d";
    };
  };
  timer = calendar: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = calendar;
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
  };
  runtimeConfig =
    e:
    pkgs.writeText "backup-${e.id}.json" (
      builtins.toJSON {
        job_id = e.id;
        source_id = e.job.sourceId;
        repository_id = e.target.repository;
        borg_command = [ (borg e.target.repository) ];
        borgmatic_command = [ "${pkgs.borgmatic}/bin/borgmatic" ];
        borgmatic_config = "/etc/borgmatic.d/managed-${e.id}.yaml";
        state_directory = state;
        staging_directory = "${state}/jobs/${e.id}/staging";
        required_directories = e.job.paths;
        required_mounts = requiredMounts (e.job.requiredMounts // e.repo.requiredMounts);
        preparation_command = lib.optional (e.job.prepareCommand != null) e.job.prepareCommand;
        sqlite_roots = e.job.sqliteRoots;
        sqlite_excluded_directories = e.job.sqliteExcludedDirectories;
        required_sqlite_files = e.job.requiredSqliteFiles;
        timeout_seconds = e.job.timeoutSeconds;
        preparation_lock_wait_seconds = 3600;
        ssh_hostname = e.repo.sshHostname;
        ssh_known_hosts_file = if e.repo.sshHostname == null then null else e.repo.knownHostsFile;
        expected_repository_id = e.repo.expectedRepositoryId;
      }
    );
  localHealthConfig =
    e:
    pkgs.writeText "backup-local-health-${e.id}.json" (
      builtins.toJSON (
        notificationSettings
        // {
          source_id = e.job.sourceId;
          repository_id = e.target.repository;
          archive_prefix = "${e.job.sourceId}-complete-";
          status_file = "${state}/status/${e.id}.json";
          max_age_seconds = cfg.maxAgeSeconds;
        }
      )
    );
  retentionArgs =
    r:
    lib.concatStringsSep " " (
      lib.mapAttrsToList (
        name: count: "--${lib.replaceStrings [ "_" ] [ "-" ] name} ${toString count}"
      ) r.retention
    );
  operation =
    name: verify:
    pkgs.writeShellScript "backup-${if verify then "verify" else "maintain"}-${name}" ''
      set -euo pipefail
      ${health name "require-fresh"}
      ${
        if verify then
          ''
            ${borg name} check --verify-data
          ''
        else
          ''
            ${borg name} check --repository-only
            ${borg name} prune --glob-archives ${lib.escapeShellArg "${repos.${name}.sourceId}-complete-*"} ${retentionArgs repos.${name}}
            ${borg name} compact
            ${borg name} check --archives-only --glob-archives ${lib.escapeShellArg "${repos.${name}.sourceId}-complete-*"} --last 1
          ''
      }
    '';
  serve =
    name:
    pkgs.writeShellScript "backup-serve-${name}" ''
      set -euo pipefail
      ${guard name}
      cd ${lib.escapeShellArg repos.${name}.url}
      exec ${pkgs.borgbackup}/bin/borg serve --append-only --restrict-to-repository .
    '';
in
{
  options.services.managedBackups = {
    enable = lib.mkEnableOption "repository-owned, independently scheduled Borgmatic backups";
    enableMaintenanceTimers = flag false "Enable scheduled upkeep only after administrator restore acceptance.";
    stateDirectory = str "/var/lib/managed-backups" "Root-private runtime state and isolated staging.";
    maxAgeSeconds = number 129600 "Maximum age of a completed backup before alerting.";
    notifications = {
      host = str "smtp.protonmail.ch" "SMTP submission host.";
      port = number 587 "Verified STARTTLS submission port.";
      recipient = str "michael@mmjo.com" "Backup alert recipient.";
      usernameFile = mkOption {
        type = types.str;
        description = "Runtime SMTP username file.";
      };
      passwordFile = mkOption {
        type = types.str;
        description = "Runtime SMTP password file.";
      };
    };
    repositories = mkOption {
      default = { };
      description = "Repositories and explicitly assigned monitoring, upkeep, and receiver roles.";
      type = types.attrsOf (
        types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              description = "Existing repository path or SSH URL.";
            };
            sourceId = mkOption {
              type = types.strMatching "[a-z0-9][a-z0-9-]*";
              description = "Completed-archive source namespace.";
            };
            passphraseFile = mkOption {
              type = types.str;
              description = "Root-private runtime passphrase file.";
            };
            expectedRepositoryId = optionalString "Optional pre-established Borg repository ID.";
            requiredMounts = mounts;
            localUser = str "root" "Repository owner used by local maintenance; never the SSH client identity.";
            sshHostname = optionalString "SSH host requiring a preverified known-host entry.";
            sshKeyFile = str "" "Runtime SSH identity; never plaintext in the Nix store.";
            knownHostsFile = str "${state}/ssh_known_hosts" "Out-of-band verified SSH server host keys.";
            generateSSHKey = flag false "Generate an unshared root-private identity locally, preserving existing keys.";
            wrapperAliases = strings "Compatibility names for the native Borg operator command.";
            monitor = flag false "Inspect completed archive freshness on this host.";
            maintenance = flag false "Run trusted maintenance on this host, gated on fresh completed data.";
            retention = mkOption {
              type = types.attrsOf types.ints.unsigned;
              default = {
                keep_daily = 7;
                keep_weekly = 4;
                keep_monthly = 12;
                keep_yearly = 2;
              };
              description = "Retention applied only to the new source-complete namespace; legacy archives untouched.";
            };
            receiver = {
              enable = flag false "Serve this local repository through a mount-guarded append-only account.";
              name = str "" "Existing native Borg receiver name to preserve.";
              appendOnlyKeys = strings "Repository-scoped authorized client public keys.";
            };
          };
        }
      );
    };
    jobs = mkOption {
      default = { };
      description = "Backup sets; every destination receives an independent execution unit and staging tree.";
      type = types.attrsOf (
        types.submodule {
          options = {
            sourceId = mkOption {
              type = types.strMatching "[a-z0-9][a-z0-9-]*";
              description = "Completed-archive source namespace.";
            };
            paths = strings "Required source directories; missing data fails closed.";
            excludes = strings "Borg exclusion patterns, including raw application databases.";
            requiredMounts = mounts;
            sqliteRoots = strings "Roots exported through SQLite's backup API.";
            sqliteExcludedDirectories = strings "Cache/media directories not scanned for SQLite.";
            requiredSqliteFiles = strings "Application databases whose presence is required.";
            prepareCommand = optionalString "Host-owned executable hook; receives BACKUP_STAGING_DIRECTORY.";
            requiredServices = strings "Application services required before preparation.";
            readWritePaths = strings "Additional sandbox writes, e.g. SQLite shared-memory roots and app exports.";
            timeoutSeconds = number 21600 "Bounded total runtime; explicitly increase for an initial seed.";
            destinations = mkOption {
              default = { };
              type = types.attrsOf (
                types.submodule {
                  options = {
                    repository = mkOption {
                      type = types.str;
                      description = "Repository role declared on this host.";
                    };
                    schedule = str "*-*-* 02:00:00" "Independent persistent systemd schedule.";
                  };
                }
              );
              description = "Destination names mapped to repository roles and independent schedules.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length entries == builtins.length (builtins.attrNames entryAttrs);
        message = "Managed backup job/destination IDs must be unique.";
      }
    ]
    ++ lib.mapAttrsToList (name: r: {
      assertion =
        (!r.receiver.enable || (r.localUser != "root" && r.receiver.name != "" && r.requiredMounts != { }))
        && (r.sshHostname == null || r.sshKeyFile != "")
        && (!r.generateSSHKey || r.sshHostname != null)
        && (r.localUser == "root" || r.sshHostname == null);
      message = "Invalid managed backup repository role: ${name}.";
    }) repos
    ++ map (e: {
      assertion = e.repo.sourceId == e.job.sourceId && e.repo.localUser == "root" && e.job.paths != [ ];
      message = "Backup ${e.id} must match its repository namespace, read required sources, and run with root file access.";
    }) entries;

    environment.systemPackages = [
      healthProgram
    ]
    ++ lib.attrValues wrappers
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: r:
        map (
          alias:
          pkgs.writeShellScriptBin alias ''
            exec ${borg name} "$@"
          ''
        ) r.wrapperAliases
      ) repos
    );
    system.build.managedBackupRuntime = runtime;
    system.build.managedBackupWrappers = wrappers;
    system.build.managedBackupMountGuards = lib.mapAttrs (name: _: guard name) repos;
    system.build.managedBackupRuntimeConfigs = lib.mapAttrs (_: e: runtimeConfig e) entryAttrs;

    services.borgmatic = {
      enable = true;
      enableConfigCheck = true;
      configurations = builtins.listToAttrs (
        map (
          e:
          lib.nameValuePair "managed-${e.id}" (
            {
              source_directories = e.job.paths ++ [
                "${state}/jobs/${e.id}/staging/sqlite"
                "${state}/jobs/${e.id}/staging/exports"
              ];
              repositories = [
                {
                  path = e.repo.url;
                  label = e.destination;
                }
              ];
              archive_name_format = "incomplete-${e.job.sourceId}-{now:%Y-%m-%dT%H:%M:%S.%f}";
              compression = "zstd,3";
              one_file_system = true;
              local_path = lib.getExe pkgs.borgbackup;
              retries = 0;
              lock_wait = 600;
              encryption_passcommand = (borgEnvironment e.target.repository).BORG_PASSCOMMAND;
              exclude_patterns = e.job.excludes;
              borg_exit_codes = map (code: {
                inherit code;
                treat_as = "error";
              }) ([ 1 ] ++ lib.range 100 127);
            }
            // lib.optionalAttrs (e.repo.sshHostname != null) { ssh_command = sshCommand e.repo; }
          )
        ) entries
      );
    };
    services.borgbackup.repos = lib.mapAttrs' (
      _: r:
      lib.nameValuePair r.receiver.name {
        path = r.url;
        user = r.localUser;
        group = r.localUser;
        allowSubRepos = false;
        authorizedKeysAppendOnly = r.receiver.appendOnlyKeys;
      }
    ) receiverRepos;
    users.users = lib.mapAttrs' (
      name: r:
      lib.nameValuePair r.localUser {
        openssh.authorizedKeys.keys = lib.mkForce (
          map (key: ''command="${serve name}",restrict ${key}'') r.receiver.appendOnlyKeys
        );
      }
    ) receiverRepos;

    systemd.tmpfiles.rules = [
      "d ${state} 0700 root root -"
      "d ${state}/jobs 0700 root root -"
      "d ${state}/locks 0700 root root -"
      "d ${state}/status 0700 root root -"
      "d ${state}/alerts 0700 root root -"
      "d ${state}/repositories 0700 root root -"
      "d /var/cache/managed-backups 0700 root root -"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: r:
        map (path: "d ${path} 0700 ${r.localUser} ${r.localUser} -") [
          (repoState name)
          "${repoState name}/security"
          "${repoState name}/keys"
          (repoCache name)
        ]
      ) repos
    );

    systemd.services = {
      borgmatic.enable = false;
      "backup-alert@" = {
        description = "Email managed backup failure %i";
        after = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig = {
          StartLimitIntervalSec = "1h";
          StartLimitBurst = 3;
        };
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          UMask = "0077";
          ExecStart = "${healthProgram}/bin/backup-health failed %i";
          Restart = "on-failure";
          RestartSec = "5min";
          TimeoutStartSec = "2min";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "${state}/alerts" ];
        };
      };
    }
    // lib.mapAttrs' (
      id: e:
      lib.nameValuePair "backup-${id}" (
        lib.recursiveUpdate (baseService e.target.repository) {
          description = "Back up ${e.job.sourceId} to ${e.target.repository}";
          after = [
            "network-online.target"
            "sops-install-secrets.service"
          ]
          ++ e.job.requiredServices
          ++ keyServices e.target.repository;
          requires = e.job.requiredServices ++ keyServices e.target.repository;
          onFailure = [ "backup-alert@${id}.service" ];
          path = [
            pkgs.coreutils
            pkgs.util-linux
            pkgs.openssh
            pkgs.docker
          ];
          environment = borgEnvironment e.target.repository;
          unitConfig = {
            StartLimitIntervalSec = "1d";
            StartLimitBurst = 3;
          };
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${runtime}/runner.py --config ${runtimeConfig e}";
            TimeoutStartSec = e.job.timeoutSeconds + 60;
            Restart = "on-failure";
            RestartSec = "30min";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = "read-only";
            ProtectSystem = "strict";
            ReadWritePaths = [
              state
              "/var/cache/managed-backups"
            ]
            ++ e.job.readWritePaths
            ++ lib.optional (e.repo.sshHostname == null) e.repo.url;
          };
        }
      )
    ) entryAttrs
    // lib.mapAttrs' (
      id: e:
      lib.nameValuePair "backup-freshness-${id}" {
        description = "Check ${e.job.sourceId} local completion record for ${e.target.repository}";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        onFailure = [ "backup-alert@freshness-${id}.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          UMask = "0077";
          TimeoutStartSec = "2min";
          ExecStart = "${pkgs.python3}/bin/python3 ${runtime}/health.py --config ${localHealthConfig e} check-local";
        };
      }
    ) entryAttrs
    // lib.mapAttrs' (
      name: r:
      lib.nameValuePair "backup-key-${name}" {
        description = "Provision private backup identity for ${name}";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          UMask = "0077";
        };
        script = ''
          set -euo pipefail
          parent=${lib.escapeShellArg (builtins.dirOf r.sshKeyFile)}
          ${pkgs.coreutils}/bin/install -d -m 0700 "$parent"
          if [ ! -e ${lib.escapeShellArg r.sshKeyFile} ]; then
            temporary="$(${pkgs.coreutils}/bin/mktemp -d "$parent/.new-key.XXXXXX")"
            trap '${pkgs.coreutils}/bin/rm -rf "$temporary"' EXIT
            ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C backup-${name} -f "$temporary/key"
            ${pkgs.coreutils}/bin/mv "$temporary/key" ${lib.escapeShellArg r.sshKeyFile}
          fi
          ${pkgs.coreutils}/bin/chmod 0400 ${lib.escapeShellArg r.sshKeyFile}
          ${pkgs.openssh}/bin/ssh-keygen -y -f ${lib.escapeShellArg r.sshKeyFile} >${lib.escapeShellArg "${r.sshKeyFile}.pub"}
          ${pkgs.coreutils}/bin/chmod 0644 ${lib.escapeShellArg "${r.sshKeyFile}.pub"}
        '';
      }
    ) (lib.filterAttrs (_: r: r.generateSSHKey) repos)
    // lib.mapAttrs' (
      name: r:
      lib.nameValuePair "borgbackup-repo-${r.receiver.name}" {
        unitConfig.RequiresMountsFor = builtins.attrNames r.requiredMounts;
        serviceConfig.UMask = "0077";
        preStart = ''
          ${guard name}
          ${pkgs.coreutils}/bin/install -d -m 0711 -o root -g root ${lib.escapeShellArg (builtins.dirOf r.url)}
        '';
        postStart = "${pkgs.coreutils}/bin/chmod 0700 ${lib.escapeShellArg r.url}";
      }
    ) receiverRepos
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "backup-monitor-${name}" (
        lib.recursiveUpdate (baseService name) {
          description = "Independently inspect completed archives in ${name}";
          serviceConfig = {
            TimeoutStartSec = "20min";
            ExecStart = health name "check-repository";
          };
        }
      )
    ) (lib.filterAttrs (_: r: r.monitor) enabledRepos)
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "backup-maintain-${name}" (
        lib.recursiveUpdate (baseService name) {
          description = "Check, prune completed backups, and compact ${name}";
          serviceConfig.ExecStart = "${pkgs.util-linux}/bin/flock -w 600 ${state}/locks/repository-${name}.lock ${operation name false}";
        }
      )
    ) (lib.filterAttrs (_: r: r.maintenance) enabledRepos)
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "backup-verify-${name}" (
        lib.recursiveUpdate (baseService name) {
          description = "Verify all data, including legacy archives, in ${name}";
          serviceConfig.ExecStart = "${pkgs.util-linux}/bin/flock -w 600 ${state}/locks/repository-${name}.lock ${operation name true}";
        }
      )
    ) (lib.filterAttrs (_: r: r.maintenance) enabledRepos);

    systemd.timers = {
      borgmatic.enable = false;
    }
    // lib.mapAttrs' (id: e: lib.nameValuePair "backup-${id}" (timer e.target.schedule)) entryAttrs
    // lib.mapAttrs' (
      id: _:
      lib.nameValuePair "backup-freshness-${id}" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30min";
          OnUnitActiveSec = "1h";
        };
      }
    ) entryAttrs
    // lib.mapAttrs' (name: _: lib.nameValuePair "backup-monitor-${name}" (timer "*-*-* 10:00:00")) (
      lib.filterAttrs (_: r: r.monitor) enabledRepos
    )
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "backup-maintain-${name}" (
        (timer "Sun *-*-* 06:00:00")
        // {
          wantedBy = lib.optional cfg.enableMaintenanceTimers "timers.target";
        }
      )
    ) (lib.filterAttrs (_: r: r.maintenance) enabledRepos)
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "backup-verify-${name}" (
        (timer "Sun *-*-01..07 12:00:00")
        // {
          wantedBy = lib.optional cfg.enableMaintenanceTimers "timers.target";
        }
      )
    ) (lib.filterAttrs (_: r: r.maintenance) enabledRepos);
  };
}
