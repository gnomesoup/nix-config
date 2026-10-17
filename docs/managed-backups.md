# Hoth and Ferrix: shared backup deployment

Status: declarative implementation; host activation and recovery acceptance remain
administrator-operated. Nothing in the build checks proves a production backup.

## Configuration and scope

`hosts/modules/backups.nix` implements `services.managedBackups`. Source sets,
repository roles, and application hooks remain in the owning host's configuration:

- `hosts/ferrix/backups.nix`: personal files, Inigo, SilverBullet, relay, Zulip
  state, consistent SQLite snapshots, and the existing validated Zulip export.
- `hosts/hoth/backups.nix`: home, Home Assistant, Dad and AFP Northwestern backups,
  both supplied Immich media locations, PostgreSQL export, and Frigate coverage.
- `hosts/hoth/borg-repositories.nix`: Ferrix's append-only receiver, independent
  repository monitoring, and Hoth-held maintenance identities.

Hoth's stale PhotoPrism and Frigate-volume sources are removed. AFP Northwestern
uses `/mnt/backup1/backups/afp-northwestern`. Both data disks require their supplied
UUIDs. A missing required source disk fails both affected jobs; only a failure
specific to one destination is isolated from the other destination's attempt.

Frigate configuration and a validated SQLite snapshot are included. Its effective
database path is checked through the container-local read-only configuration API;
it must be `/config/frigate.db`. A custom location or unavailable configuration
fails closed, even if a stale default file exists. Existing whole-home coverage is
preserved. No response was received to the media-scope question: this migration
must not silently drop previously selected footage. Review its size and BorgBase
quota before seeding; excluding continuous recordings remains an explicit choice.
The SQLite snapshot and live media traversal are not a joint point-in-time image.

Immich's supplied anonymous `/data` volume and legacy bind root are both included
pending the separate v3 upgrade. A hook verifies those exact container mounts,
checks free staging space, and runs `pg_dumpall` inside `immich_postgres`, using
its own matching client tools and authentication. All databases and roles in that
container are exported, so no application database name is guessed. The raw
`/home/mpfammatter/docker/immich-db` directory remains excluded. Dumps include
sensitive role metadata: staging is root-private and Borg encryption is required.
A container/storage migration intentionally fails the mount guard until reviewed.

Ordinary Docker volumes are not a general database-backup adapter. Application
recovery, external Immich libraries, unusual database filenames, and other
containers require explicit coverage review. No live database is restored here.

## Units and success semantics

| Source | Local destination unit | Offsite destination unit |
| --- | --- | --- |
| Ferrix | `backup-ferrix-hoth.service` | `backup-ferrix-borgbase.service` |
| Hoth | `backup-hoth-local.service` | `backup-hoth-borgbase.service` |

The persistent schedules are Ferrix 02:00/03:00 and Hoth 00:30/01:30 in the host's
configured timezone, with ten minutes of jitter. The upstream all-configurations
Borgmatic service/timer is disabled; compatibility service aliases are not extra
schedulers. Transfers have a six-hour deadline and up to three systemd starts per
day, with thirty-minute restart delays. Increase `jobs.NAME.timeoutSeconds`
explicitly for a large first seed, then restore the steady-state limit.

Each destination has its own staging tree under
`/var/lib/managed-backups/jobs/JOB-DESTINATION/staging`. Only application export
preparation is serialized; that lock is released before upload. One blocked
upload cannot hold another destination's preparation lock. Staging and credentials
are never part of a world-readable Nix derivation.

An archive is created in an `incomplete-SOURCE-` namespace. Only a zero-exit create
followed by successful promotion yields `SOURCE-complete-*` and an atomic status
record. Warnings, failed creates, and checkpoints cannot satisfy freshness checks.
The journal records static execution stages and subprocess exit status, without
printing child output, arguments, exports, or credentials.
Abandoned incomplete archives are not automatically pruned; inspect before manual
cleanup rather than deleting possible recovery points blindly.

Each source checks local completion records hourly. Hoth checks all four
repositories daily through `backup-monitor-REPOSITORY.service`. Alerts use
certificate-verified STARTTLS and the existing encrypted SMTP credentials through
generic `backup/email-*` references. Delivery must be tested from each host.

Maintenance and full verification share one operation lock per repository and
use bounded Borg lock waits. They require a fresh completed archive. Retention is
7 daily, 4 weekly, 12 monthly, and 2 yearly, applied only to the new completed
namespace. Historical `endor-*` and older `ferrix-*` archives are not pruned by the
new policy. Full verification reads historical data too.

**Automatic maintenance and full-verification timers are not installed into
`timers.target` until `services.managedBackups.enableMaintenanceTimers = true`.**
Enable that on Hoth only after the restore gates below. The units remain available
for explicit administrator invocation. Existing append-only limitations remain:
trusted compaction can physically remove client-deleted data. This is not immutable
or ransomware-proof storage; stop upkeep if compromise is suspected.

## Deployment gates

Inigo has no remote SSH or administrator access. Run these steps at the respective
host's administrator console. Pull the backup implementation commit into the
administrator's checkout on both hosts before building or activating it.

1. Preserve offline SOPS recovery material, repository keys, and passphrases.
   Keep access to historical Hoth archives through the old configuration while
   testing a replacement. Never reinitialize either existing Hoth repository.
2. Build before activation:

   ```sh
   nix build --no-link path:$PWD#checks.x86_64-linux.managed-backups
   nix build --no-link path:$PWD#nixosConfigurations.hoth.config.system.build.toplevel
   nix build --no-link path:$PWD#nixosConfigurations.ferrix.config.system.build.toplevel
   ```

3. Activate Hoth first:

   ```sh
   sudo nixos-rebuild switch --flake path:$PWD#hoth
   findmnt --mountpoint /mnt/backup1 --output TARGET,UUID,FSTYPE
   findmnt --mountpoint /mnt/backup2 --output TARGET,UUID,FSTYPE
   sudo systemctl start borgbackup-repo-ferrix.service
   sudo systemctl start backup-key-hoth-borgbase.service
   sudo systemctl start backup-key-ferrix-borgbase.service
   ```

4. Hoth generates a new dedicated identity for its existing BorgBase repository.
   Obtain only its public key via the console:

   ```sh
   sudo cat /var/lib/managed-backups/identities/hoth-borgbase.pub
   ```

   Register that public key with Hoth's existing `x387mg6b` repository, with full
   access for its source/maintenance role. Preserve the old personal-key access
   until historical and new restores pass. The old key is neither read nor copied
   by this implementation. Hoth's separate Ferrix maintenance key retains its
   existing private-file location and is never shared with Ferrix. If it has not
   been registered, register only its `.pub` with full access to Ferrix's distinct
   `hlek3m3n` repository. Ferrix's existing client keys remain append-only.

5. Rebuilding either host installs the pinned public server keys at
   `/etc/managed-backups/ssh_known_hosts`, root-owned and read-only. Hoth's key
   was supplied from its administrator console; both BorgBase ED25519 keys were
   matched to the fingerprints shown in the repository account. The shared source
   is `hosts/modules/backup-ssh-known-hosts`; no manual trust-file installation or
   network key scan is required at activation. For future rotation, verify new
   fingerprints out of band before changing source. Never bypass strict checking.
6. Inventory Hoth's existing repositories and restore a known historical file:

   ```sh
   sudo backup-borg-hoth-local info
   sudo backup-borg-hoth-local list --last 3
   sudo backup-borg-hoth-borgbase info
   sudo backup-borg-hoth-borgbase list --last 3
   ```

   Confirm expected repository identities and retain them offline. The optional
   `expectedRepositoryId` setting can pin those verified IDs. The scheduled runner
   never initializes repositories. For genuinely new, empty Ferrix repositories,
   use the original initialization/recovery instructions in `ferrix-backups.md`;
   never treat authentication failure as permission to initialize.
7. Run the two Hoth jobs independently, then activate and test Ferrix:

   ```sh
   sudo systemctl start backup-hoth-local.service
   sudo systemctl start backup-hoth-borgbase.service
   # At Ferrix's console:
   sudo nixos-rebuild switch --flake path:$PWD#ferrix
   sudo systemctl start backup-ferrix-hoth.service
   sudo systemctl start backup-ferrix-borgbase.service
   ```

   Inspect each unit's journal, exact completed archive, and status marker. A
   successful build, an active timer, or an old archive is not proof of protection.
   These first runs must also verify access from the actual generated unit's
   root/application ownership, Docker socket, and read-only sandbox: local helper
   tests do not exercise the production systemd sandbox or Docker permissions.
   The old `ferrix-borg-hoth`/`ferrix-borg-borgbase` operator wrappers remain aliases.
8. On each host run `sudo backup-health test` and confirm actual receipt. At
   Hoth, start `backup-monitor-hoth-local`, `backup-monitor-hoth-borgbase`,
   `backup-monitor-ferrix-hoth`, and `backup-monitor-ferrix-borgbase` separately.
   Check each result and deliberately exercise stale and failed-backup alerts in
   a disposable setup, not by damaging production repositories.
9. Configure BorgBase missed-backup alerts for **both repositories** to Michael's
   email. This is an outstanding provider-account action, not automated by Nix.
   It is essential for detecting a dead Hoth; Hoth cannot send its own outage
   alert. Repository activity is only a secondary signal, not completed-archive
   verification.
10. Complete restoration, check quotas/staging space and upload duration, then set
    `services.managedBackups.enableMaintenanceTimers = true` in Hoth's declaration
    and rebuild. Do not enable this simply because the first upload returned zero.

## Restoration acceptance

Extract into a root-private disposable directory, never over a running service.
Use an exact archive name from the appropriate `backup-borg-REPOSITORY list`.
Borg paths are relative to the archive root; list them before selecting files.

- Read a known **historical Hoth** archive at each destination.
- Read a new completed archive for each host/destination and compare a known file.
- Restore SQLite snapshots from the destination-specific `staging/sqlite` tree,
  run integrity checks, and inspect committed application data. Review ownership
  metadata; remove stale WAL/SHM only while replacing an offline database.
- Restore Immich's `staging/exports/immich.sql` into a disposable PostgreSQL 14
  environment with the deployment's matching extensions. Inspect assets and roles,
  then test with isolated Immich v2.7.5 and restored media. The v3 upgrade has its
  own compatibility and migration procedure; do not test by upgrading production.
- Restore Frigate configuration, snapshot, and selected media into isolated
  Frigate 0.17.1 and inspect events/media. The DB alone cannot recover footage.
- Restore the staged Zulip custom-format dump and uploads in an isolated matching
  deployment, as described in `ferrix-backups.md`. `pg_restore --list` is validation,
  not a substitute for restoring and inspecting messages.
- Confirm a home file, SilverBullet note/attachment, and Inigo conversation.

Old helper files are retained for rollback and the existing Zulip adapter. Remove
obsolete implementations only after administrator read-back and restore acceptance.

## Local checks

Executed locally: both full NixOS host builds, the shared backup check (67 tests,
no skips), and `nix flake check path:$PWD`. These passed. The shared check includes
the installed runtime CLI and the actual Hoth/Ferrix exclusion policies, not only
standalone helpers. Hoth's initial ramdisk derivation is unchanged from the base
commit; initrd dependency warnings are not introduced by this backup change.

```sh
nix build --no-link path:$PWD#checks.x86_64-linux.managed-backups
nix flake check --no-build path:$PWD
python3 -W error::ResourceWarning -m unittest -v hosts/hoth/backup-applications_test.py
git diff --check
```

Unit tests use explicit test fixtures and mocked external boundaries. The shared
check additionally exercises real encrypted Borg create/extract/verification and
SQLite WAL recovery. These checks never connect to production repositories or
read production passwords. Live database restoration, SMTP delivery, remote key
registration, provider alerts, and activation remain administrator acceptance gates.
