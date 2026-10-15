# Ferrix backups: deployment and recovery

## What is configured

Ferrix creates independent nightly Borg archives on Hoth and BorgBase:

- Hoth: `/mnt/backup2/borg/ferrix`, over SSH to `hoth.tailbb897.ts.net`.
- BorgBase: `ssh://hlek3m3n@hlek3m3n.repo.borgbase.com/./repo`.
- Nightly starts: Hoth 02:00, BorgBase 03:00, America/New_York, with up to ten
  minutes of jitter. Persistent timers catch up after downtime. A shared lock
  serializes preparation and uploads; each destination has independent retries.
- Retention on Hoth: 7 daily, 4 weekly, 12 monthly, and 2 yearly recovery points.
  Pruning/compaction runs weekly, after requiring a backup less than 36 hours old
  and checking repository integrity. Full data verification runs monthly.
- Email failures and backups older than 36 hours to `michael@mmjo.com`. SMTP uses
  the existing Zulip service credentials with certificate-verified STARTTLS.
  Duplicate alerts for the same problem are throttled to once per day.
- Ferrix checks local success records hourly. Hoth independently inspects both
  repositories daily, so it can detect a failed or powered-off Ferrix.

These are configuration changes, not proof of live backups. Complete the setup
and acceptance tests below before considering Ferrix protected.

## Data and formats

Included:

- `/home/mpfammatter`: personal files, projects, configuration, and age identity.
- `/var/lib/inigo`: assistant sessions, memory, skills, profiles, and workspace.
- `/var/lib/private/silverbullet`: actual DynamicUser storage, including both
  spaces, attachments, and Git history, rather than just its public symlink.
- `/var/lib/remote-pi-relay`: persistent relay state.
- `/var/lib/docker/volumes/zulip_zulip/_data`: Zulip uploads and application state.
- `/var/lib/ferrix-backup/sqlite`: consistent SQLite snapshots and their metadata.
- `/var/lib/ferrix-backup/zulip/database.dump`: validated Zulip database export.
- `/etc/ferrix-backup-recovery`: copied encrypted credentials and policy metadata.
  The mutable Nix checkout is also included under Inigo's state.

Caches, Trash, `node_modules`, and old Zulip dump files are excluded. The Hoth
media mounts, Docker image layers, PostgreSQL's raw volume, and the Nix store are
not sources. Nix store symlinks are preserved as symlinks, not traversed.

SQLite files ending in `.db`, `.sqlite`, or `.sqlite3` in the configured service
roots are copied through SQLite's backup API, including committed WAL changes,
and checked with `quick_check`. Their live files and sidecars are excluded from
Borg. Snapshots mirror absolute source paths beneath the snapshot directory;
`manifest.json` records original paths, ownership, and permissions. Review new
state formats when upgrading services: this is not an automatic backup adapter
for every possible database format or filename.

The Zulip hook checks the application volume and known 11.6-1 entrypoint, uses
`app:backup`, requires exactly one new dump, and validates it with
`pg_restore --list`. It then copies the dump to root-only staging and removes
only that newly generated source dump. Old administrator-created dumps are not
deleted. Despite the upstream `.sql` suffix, this is PostgreSQL custom format.
The export does not contain uploads, so the application volume is also included.

Snapshots are individually consistent, not a single atomic snapshot across all
services and ordinary files. Applications stay online during backup. A failed
export, insufficient staging space, missing source, or Borg warning must fail the
job rather than record success. Staging preserves at least 2 GiB of free space;
large exports may still need more free space or a different staging filesystem.

## Security boundaries

The shared SOPS bundle contains two independent repository passphrases and two
append-only client SSH keys. It is encrypted to the repository's existing age
recipients. No plaintext secret is committed or embedded in a derivation.

Hoth generates its BorgBase maintenance key locally, root-only, at activation.
It is deliberately absent from shared SOPS: Ferrix can decrypt shared secrets,
so putting the full-access private key there would defeat append-only isolation.
Register only the new Hoth-generated public maintenance key for full access.

Hoth's source account is restricted to `borg serve`, append-only, and this one
repository. Both directory provisioning and every SSH connection verify the
expected backup disk UUID. Missing disks fail closed instead of creating a
repository on Hoth's root filesystem. Maintenance uses the repository account
locally so it does not leave root-owned segments behind.

Append-only is not immutable storage. Weekly trusted compaction can physically
remove data previously marked deleted by a client. This gives a recovery window,
not permanent ransomware protection. If compromise is suspected, stop maintenance
and preserve the repository before allowing any compaction or pruning. BorgBase
account access and Hoth root access remain destructive authorities.

## Initial deployment: administrator required

Do not replace an existing repository's passphrase or initialize over existing
backups. If Borg reports an existing repository or an authentication failure,
stop and investigate rather than treating it as an empty destination.

1. Transfer this working tree, including new files, to the administrator's normal
   checkout on both machines. These changes have not been committed or pushed.
   Each machine must be able to decrypt `secrets/ferrix-backups.yaml` with its
   configured SOPS identity. Preserve a working recovery identity outside Ferrix.
2. Build both configurations. Use a `path:` flake while new files are untracked:

   ```sh
   nix build --no-link path:$PWD#checks.x86_64-linux.ferrix-backups
   nix build --no-link path:$PWD#nixosConfigurations.hoth.config.system.build.toplevel
   nix build --no-link path:$PWD#nixosConfigurations.ferrix.config.system.build.toplevel
   ```

3. On Hoth, activate its configuration, then verify the disk and receiver:

   ```sh
   sudo nixos-rebuild switch --flake path:$PWD#hoth
   findmnt --mountpoint /mnt/backup2 --output TARGET,UUID,FSTYPE
   sudo systemctl start borgbackup-repo-ferrix.service
   sudo systemctl start ferrix-backup-maintenance-key.service
   ```

   Persistent upkeep/monitor timers may initially fail before repository setup is
   complete. This is expected and should generate an alert, not initialize data.

4. Register SSH keys with BorgBase, scoped only to the supplied repository:
   - `borgbase` from `hosts/modules/ferrix-backup-public-keys.json`: append-only.
   - Hoth's locally generated maintenance public key: full repository access.
     Obtain only the `.pub` file via Hoth's administrator console; never copy its
     private key onto Ferrix. The public file is inside Hoth's root-only backup
     state directory and has the same basename as the maintenance key plus `.pub`.
   - Do not grant BorgBase access to Ferrix's separate Hoth client key.

5. Verify SSH host keys out of band. Never trust `ssh-keyscan` output by itself.
   Compare Hoth's candidate key against its console's host-key fingerprint:

   ```sh
   sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

   Verify BorgBase against its account-provided or officially published host-key
   fingerprints. Install a root-owned, mode-0600 OpenSSH known-hosts file at
   `/var/lib/ferrix-backup/ssh_known_hosts` on both hosts. Ferrix needs entries for
   `hoth.tailbb897.ts.net` and `hlek3m3n.repo.borgbase.com`; Hoth needs BorgBase.
   This file is an intentional trust bootstrap gate, not trust-on-first-use.

6. On Hoth, initialize the two new, empty repositories with its wrappers:

   ```sh
   sudo ferrix-borg-hoth init --encryption=repokey-blake2
   sudo ferrix-borg-borgbase init --encryption=repokey-blake2
   ```

   These wrappers select the generated passphrases without printing them.
   Initialization is manual and never performed by scheduled jobs. The local
   wrapper drops to `ferrix-borg`, preserving correct ownership from the start.

7. Export both repository keys to secure offline media using `key export` with
   each Hoth wrapper. Preserve their separate passphrases in an offline recovery
   process or password manager, as well as a valid SOPS recovery identity. The
   encrypted bundle or repository key export alone is not enough if the only
   usable decryption credentials disappear with Ferrix.
8. On Ferrix, activate and run the first full backups:

   ```sh
   sudo nixos-rebuild switch --flake path:$PWD#ferrix
   sudo systemctl start ferrix-backup-hoth.service
   sudo systemctl start ferrix-backup-borgbase.service
   sudo ferrix-borg-hoth list --last 2
   sudo ferrix-borg-borgbase list --last 2
   ```

9. On each host, send a delivery test with `sudo ferrix-backup-health test` and
   confirm receipt at Michael's inbox. On Hoth, run both
   `ferrix-backup-monitor-DESTINATION.service` units after the initial archives
   exist. Confirm their results and inspect any failures with `journalctl`.
10. Perform the restore exercise below for both destinations. Then review quota,
    initial archive size, upload duration, and staging space before leaving the
    schedules unattended. BorgBase's own missed-backup alert is also recommended:
    configure it to Michael's email in the provider account to cover a failed
    Hoth as well as a failed Ferrix.

## Restore exercise and disaster recovery

Use an isolated extraction directory, never the live service root. On Ferrix,
choose an exact archive name from `sudo ferrix-borg-DESTINATION list`; the raw
Borg wrappers do not interpret `latest` as an archive alias.

For example, after replacing `ARCHIVE` with an actual name:

```sh
sudo install -d -m 0700 /var/lib/ferrix-restore-test
sudo sh -c 'cd /var/lib/ferrix-restore-test && \
  /run/current-system/sw/bin/ferrix-borg-borgbase extract ::ARCHIVE'
```

For large backups, select specific archive paths instead of extracting all data.
Repeat into a separate empty directory with `ferrix-borg-hoth` to test Hoth.

Verify these before declaring success:

- A known home file and a SilverBullet note plus an attachment match expectations.
- Inigo's snapshot `state.db` opens and passes SQLite integrity checks, and known
  sessions can be inspected from the restored copy without changing live state.
- The staged Zulip dump passes `pg_restore --list`, then restores into a separate
  disposable PostgreSQL instance of a compatible version. Inspect messages and
  restore uploads into an isolated matching Zulip deployment; listing its TOC is
  not a substitute for an actual restoration.
- Both repositories have usable archives and decryption material survives away
  from Ferrix. Restore metadata is not a substitute for testing the actual data.

For real service recovery, stop all affected writers before replacing files.
Overlay SQLite snapshots onto their original paths after restoring ordinary
files; remove obsolete `-wal`/`-shm` files while the service is stopped, and restore
permissions/ownership from reviewed metadata. Respect SilverBullet's DynamicUser
storage and allow its unit to reestablish ownership instead of blindly restoring
an obsolete transient UID. Restart services and verify application behavior.

Zulip's destructive `app:restore` accepts a basename under `/data/backups`. Copy
an extracted `database.dump` there with a new `.sql` filename and use the exact
Compose file `/etc/zulip/compose.yaml`. Restore application uploads/configuration
as well, and verify secret configuration is recreated from SOPS. Test this in an
isolated deployment first; never run it against live Zulip as a smoke test.

## Validation commands

```sh
python3 -W error::ResourceWarning -m unittest -v \
  hosts/ferrix/backup-state_test.py hosts/modules/ferrix-backup-health_test.py
nix build --no-link path:$PWD#checks.x86_64-linux.ferrix-backups
nix flake check --no-build path:$PWD
git diff --check
```

The Nix check includes an actual encrypted Borg create/extract/verify roundtrip,
using the configured exclusions, plus snapshot safety and email/freshness tests.
Local tests do not prove remote connectivity, live Docker access, SMTP delivery,
activation, or successful application recovery. Those remain acceptance gates.
