# Shared Hoth and Ferrix backup workflow

Status: implementation underway in the shared module and host declarations.
See [deployment and acceptance gates](managed-backups.md). Host activation,
production backup/restore verification, and provider alerts remain administrator
actions; this plan is not evidence that those gates have passed.

## Recommendation

Use one reusable Nix module and the existing Borgmatic engine. Each host declares
its sources, preparation hooks, repositories, credentials, mounts, and schedules.
The module generates the units and checks. Do not build one monolithic service
that serializes all machines or hides which destination failed.

Keep separate source/destination units for isolation, but generate them from the
same implementation. Receiving repositories, maintenance, and monitoring are
separate configurable roles, not services hard-coded to Ferrix.

## Confirmed current state

### Hoth's own backup

`hosts/hoth/default.nix:241` enables Borgmatic with these destinations:

- `/mnt/backup2/borg/endor`: local repository, retaining its historical name.
- `x387mg6b.repo.borgbase.com`: Hoth's existing offsite repository, distinct from
  Ferrix's `hlek3m3n.repo.borgbase.com` repository. Its checked-in URL is configured
  with a real username, not a placeholder; authentication is not verified.

The evaluated configuration enables `borgmatic.service` and `borgmatic.timer`
and installs the timer into `timers.target`. The pinned upstream timer runs daily
with persistence and up to ten minutes of jitter. The pinned upstream service:

- Has `ConditionACPower=true`, but Hoth is an always-powered Intel NUC. This is
  not a useful explanation for its reported failure under normal operation.
- Has no automatic service restart after failure.
- Uses `ProtectSystem=full`, not `strict`. A missing repository-specific
  `ReadWritePaths` override is therefore not evidence of a read-only `/mnt` bug.
- Runs all configured destinations through the default Borgmatic invocation.

The repository declares no Hoth-specific source/destination mount checks,
backup failure email, success recording, or backup freshness monitor for this
legacy job. The newly added Ferrix monitoring only recognizes `ferrix-*` archives;
it does not cover Hoth's `endor-*` archives.

Currently declared Hoth sources are:

- `/home/mpfammatter`
- Obsolete PhotoPrism originals and storage on `/mnt/photoprism`; PhotoPrism is
  retired and these paths should be removed from future backup declarations.
- Frigate's `docker_frigatedb` Docker volume data
- Incoming Home Assistant backups on `/mnt/backup2`
- Dad's backups and the Immich library on `/mnt/backup1`
- AFP Northwestern backups are incorrectly declared on `/mnt/backup2`; the user
  confirms the correct source is `/mnt/backup1/backups/afp-northwestern`.

Issues to address alongside the confirmed missing-source failure:

1. The declared data disks use `nofail`. A booted server does not establish that
   required data or the repository disk is mounted. Validate each expected UUID
   before reading sources or creating/writing a local repository.
2. Immich's database directory is excluded, with no export hook configured here.
   Verify whether Immich's own database backups or another export job already
   supply usable dumps inside the included media tree. The name `library` does
   not establish whether the source is the whole upload root or a subdirectory.
3. Frigate's database volume is read as ordinary files. Replace this with an
   explicit configuration, consistent SQLite, and selected-media backup policy.
4. The job depends on a personal interactive SSH key. Replace this with a
   dedicated, repository-scoped key after proving access to the existing repo.
5. Its retention differs from Ferrix: one daily instead of seven. Unify the
   default explicitly rather than changing historical retention accidentally.
6. Several sources and the local repository share `/mnt/backup2`. That local copy
   is not independent protection against failure of that disk. Offsite backup
   matters; this plan does not expand the source set to all media or Time Machine.

The `endor` directory/archive prefix is legacy naming, not proof of failure.
Preserve the existing repository identity, passphrase, archives, and filters
until an explicit migration proves historical restore access.

### Confirmed runtime failure and deployed applications

User-provided Hoth status/journal output shows an active, enabled timer and failed
scheduled runs on October 13, 14, 15, and 16, 2026. The October 16 run exits with
status 1 at 00:08:51 EDT. Borgmatic rejects these configured source paths:

- `/mnt/photoprism/photoprism/originals`
- `/mnt/photoprism/photoprism/storage`
- `/var/lib/docker/volumes/docker_frigatedb/_data`
- `/mnt/backup2/backups/afp-northwestern`

The same source validation failure is reported for both repositories. This is
not an absent timer or an AC-power skip. No successful backup is established by
these runs, and repository authentication remains unproven by this output.

The inherited `borgmatic.pw` warning is not the terminating failure: systemd
reports it as skipped, then executes Borgmatic, which rejects the missing source
paths. Keep the SOPS passphrase mechanism; do not create an unrelated credential
as a speculative fix. Remove the irrelevant inherited setting when replacing the
upstream runner with explicitly generated units.

The user confirms PhotoPrism is retired. Remove those source declarations, but
preserve existing data and historical archives. Frigate is active, so its missing
old volume path must be replaced with verified current mounts and a consistent
backup, not silently removed from coverage. AFP Northwestern remains included:
replace its stale source with `/mnt/backup1/backups/afp-northwestern`, as confirmed
by the user, and require the expected `/mnt/backup1` filesystem. A missing path
must not be fixed by creating an empty directory or globally ignoring sources.

Observed container inventory:

- `immich_server`: `ghcr.io/immich-app/immich-server:v2.7.5`
- `immich_machine_learning`: matching `v2.7.5`
- `immich_postgres`: `tensorchord/pgvecto-rs:pg14-v0.2.0`
- `frigate`: `ghcr.io/blakeblackshear/frigate:0.17.1`
- A separate container named `postgres` runs `postgres:15`; do not confuse it
  with Immich's PostgreSQL 14 service or infer its owning application.

Use Immich's deployed database container and matching tools/extensions for export
and restore verification. This plan does not upgrade its database or application.
Use Frigate 0.17.1's actual configuration and mounts for its SQLite/media adapter.

Other observed services include Calibre-Web, Mealie, OpenClaw, Proton Mail Bridge,
and Immich Redis. Inventory their durable-state needs during the whole-host
review. Their presence does not establish either existing backup coverage or
permission to add all caches/media/credentials to the source set automatically.

### Supplied mount mappings and remaining Immich storage check

User-provided `findmnt` output confirms the expected ext4 filesystem identities:

- `/mnt/backup1`: `4ce63432-8223-495e-95a0-8aac69181517`
- `/mnt/backup2`: `f8c69028-4b3f-4f4a-9f10-c064aaede45c`

Frigate 0.17.1 maps:

- `/home/mpfammatter/docker/frigate` to `/config`.
- `/home/mpfammatter/docker/frigate/media` to `/media/frigate`.
- A tmpfs to `/tmp/cache`; exclude this regenerable cache.

Resolve the configured database path inside this configuration; the default
`/config/frigate.db` would map into the verified config bind, not the missing
legacy named-volume path. The general `/home/mpfammatter` source already walks
both this application's configuration and its nested media directory. Explicit
application policies must therefore prevent raw DB/sidecar copying and prevent
unselected video from slipping into the backup through the broad home traversal.
Test include/exclude rules against both home and application source coverage.

Immich's database maps `/home/mpfammatter/docker/immich-db` to PostgreSQL's data
directory. Keep the raw-data exclusion on the general home source and add a
restorable export from `immich_postgres`; do not back up that live directory.

Immich's server has two different storage mounts:

- `/mnt/backup1/immich` is bound to legacy `/usr/src/app/upload`.
- `/data` is an anonymous Docker-managed volume named:

  ```text
  4e5d855e02e90178383e8ccb1495a04c9276c8660f890bb777824af98fcfd315
  ```

  Its host storage is `_data` beneath that volume's directory in
  `/var/lib/docker/volumes`.

Version-pinned upstream v2.7.5 Dockerfile declares `/data` as a volume, and its
Compose example binds the upload root to `/data`. The supplied legacy bind does
not, on its own, establish that it is the application's active media root.
The user's targeted environment check returned `(unset)`. The user plans an
Immich v3 upgrade soon and explicitly does not want extended investigation of
the legacy storage layout. Defer that investigation and storage migration to the
upgrade task. For current backup planning, conservatively preserve both supplied
media locations plus a consistent PostgreSQL export. Do not recreate containers,
prune the anonymous volume, or redirect mounts as a speculative fix. This is
interim coverage, not a claim that storage migration or restoration was tested.

The current `/mnt/backup1/immich/library` source is narrower than the supplied
legacy bind root and does not include the separate `/data` volume. Do not assume
that it captures uploads, profile data, and automatic database backups. If the
anonymous volume is active, protect it first; migrating to explicitly declared,
stable storage belongs to the separate v3 upgrade after a verified safety backup.

### Application coverage corrections

PhotoPrism is no longer used. Remove its source paths and obsolete database
exclusion from the new backup declaration. Do not delete existing PhotoPrism data,
unmount its disk, or erase historical archives as part of that cleanup. Its
missing paths are confirmed contributors to the current job's validation failure.

Immich remains required. Use the supplied mounts for interim conservative
coverage; do not block the shared backup work on classifying legacy media roots.
Verify the database export mechanism and include original uploads/library, profile data,
external libraries if used,
and a restorable PostgreSQL dump. Do not infer coverage from path basenames or
copy the running PostgreSQL data directory. Prefer a fresh export in the backup
hook; an existing automatic dump is acceptable only after checking completion,
freshness, inclusion in Borg, and actual restoration. Thumbnails and encoded video
can be treated as regenerable only as an explicit storage/recovery-time decision.

Frigate gets a declared application backup rather than just a Docker volume path:

- Include its configuration and any non-reproducible supporting files. Preserve
  credentials through the protected recovery mechanism, never diagnostic output.
- Resolve its configured SQLite database from the real container mount mapping.
  Current upstream defaults use `/config/frigate.db`, but the configured path to
  the old database volume is missing in the supplied logs. Verify current storage
  layout instead of relying on that obsolete source. Do not relocate
  or guess its database path as part of the backup change.
- Snapshot through SQLite's backup API into isolated staging, preserve committed
  WAL changes, validate the snapshot, and exclude live DB files and sidecars from
  the ordinary file traversal. Never use an immutable SQLite connection that
  ignores a live WAL.
- Declare media coverage separately: saved snapshots, manually exported footage,
  and continuous recordings are different retention and storage decisions. Do not
  silently include all camera footage or pretend the database contains it.
- Document that omitted footage is not recoverable from the restored database.
  If database/media point-in-time consistency is required, use a controlled
  quiesce/snapshot procedure; do not claim a live file traversal provides it.
- Test restoration with the matching Frigate version, configuration, database,
  and the chosen media set in isolation before replacing the current source.

Reference checks used the upstream Frigate Advanced Options/Full Reference Config
and Immich Backup and Restore/Backup Script documentation. Deployment-specific
paths, versions, and recording coverage still require user-run verification.

### Ferrix

`hosts/ferrix/backups.nix` has the newer export, scheduling, failure email, and
success-recording workflow. Hoth's `borg-repositories.nix` maintains and monitors
Ferrix repositories. Shared helpers still hard-code Ferrix in names, archive
matching, status paths, messages, and credential layout.

The accepted review tradeoffs remain documented. The refactor should not
silently change who holds destructive credentials or claim immutable protection.
It should, however, remove accidental scheduling coupling and make success
recognition accurate for both machines.

## Runtime diagnosis gate

Host verification is user-operated. Inigo has no configured SSH access to Hoth or
other infrastructure hosts and must not treat agent SSH access as a prerequisite.
An earlier strict connection attempt stopped at the unknown-server-key check,
before authentication; no remote commands ran and no trust bypass occurred.
The supplied runtime output confirms missing-source validation as the current
failure. Follow-up storage and application checks remain user-operated.

The backup client identities were generated specifically for this setup, not
obtained from the user's personal SSH keys. Their private halves are encrypted
in `secrets/ferrix-backups.yaml`. Hoth's separate maintenance identity is generated
locally on Hoth at activation. These client identities are distinct from SSH
server host keys; no server host keys were saved or accepted as trusted.

Initial user-run diagnostics (status, journal, container list, application mounts,
and filesystem identities have now been supplied):

```sh
systemctl list-timers --all --no-pager 'borg*' 'ferrix-backup*'
systemctl show borgmatic.timer borgmatic.service \
  -p Id -p LoadState -p ActiveState -p SubState -p Result \
  -p ConditionResult -p ExecMainStatus -p LastTriggerUSec
sudo journalctl -u borgmatic.service -b -n 100 --no-pager
findmnt --mountpoint /mnt/backup1 --output TARGET,UUID,FSTYPE
findmnt --mountpoint /mnt/backup2 --output TARGET,UUID,FSTYPE
sudo docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

Use the results to distinguish: timer never triggered, service execution failure,
missing mount/source, local permission/locking issue,
or SSH/repository authentication failure. Inspect the first meaningful journal
error and recent repository archives; `inactive` or `Result=success` alone is not
proof that a backup ran. Do not request resolved Docker environment dumps or
plaintext credentials to diagnose this.

Reproducible mount checks, already supplied by the user:

```sh
sudo docker inspect --format '{{.Name}} {{json .Mounts}}' \
  immich_server immich_postgres frigate
findmnt --mountpoint /mnt/backup1 --output TARGET,UUID,FSTYPE
findmnt --mountpoint /mnt/backup2 --output TARGET,UUID,FSTYPE
```

AFP Northwestern's correct source is `/mnt/backup1/backups/afp-northwestern`, as
confirmed by the user. Remaining immediate checks are Frigate's database/config,
its selected media coverage, and the Immich database export mechanism. The
following non-secret Immich path check is already completed and returned
`(unset)`; further legacy storage investigation is deferred to the v3 upgrade:

```sh
sudo docker exec immich_server node -e \
  'console.log(process.env.IMMICH_MEDIA_LOCATION ?? "(unset)")'
```

Restore Hoth's existing backup path first when the failure is narrowly repairable.
Do not make recovery depend on completing the whole abstraction refactor.

## Proposed shared model

Add `hosts/modules/backups.nix` with a typed, repository-owned option namespace
(for example `services.managedBackups`; this would be a new local option, not an
existing upstream NixOS API).

A backup set declares:

- Source ID, paths, exclusions, preparation hooks, and required services.
- Required mounts with expected UUIDs; explicit handling of optional datasets.
- Destinations with repository URL/path, stable identity, encryption reference,
  SSH key reference, verified host keys, and any existing archive prefixes.
- Schedule, retry/deadline policy, compression, retention, and freshness threshold.
- Per-repository maintenance placement and key capabilities.
- Alert recipient and SMTP credential references, independent of Zulip naming.

Use existing `services.borgmatic.configurations` to generate validated engine
configuration. Generate one execution unit per backup set/destination instead of
relying on the upstream all-configurations runner. This avoids changing engines
and makes AC-power policy, sandbox permissions, deadlines, and retries explicit.

Keep host-specific data declarations in:

- `hosts/ferrix/backups.nix`: personal/Inigo/SilverBullet/relay/Zulip state and
  exports; Hoth and Ferrix's existing BorgBase repository as destinations.
- `hosts/hoth/backups.nix`: active Hoth data, explicit Immich/Frigate exports and
  media policies, and existing local/offsite repositories; no retired PhotoPrism.

Reuse the SQLite backup implementation. Keep application-specific commands next
to the application/host that owns them, passing them as hooks; do not put Zulip,
Immich, Frigate, or guessed container names into the generic runner.

## Common execution contract

1. Preflight credentials and verified SSH trust, expected mounts/UUIDs, required
   sources, available staging space, repository identity, and application state.
2. Produce consistent exports in destination-specific staging. Serialize only
   preparation when required; never hold a global source lock throughout an
   unbounded transfer to one destination.
3. Create an archive in an incomplete namespace. Promote it into the completed
   source namespace only after a zero-exit backup. Checkpoints and warning/failed
   archives must not satisfy external freshness checks.
4. Record successful completion per source and destination. Report failures and
   stale backups with the same generic implementation and precise identities.
5. Apply retention/checks using explicitly assigned maintenance authority. Use
   one per-repository operation lock for maintenance and full verification, plus
   bounded Borg lock waits. Preserve append-only versus full-access semantics.
6. Clean only that job's staging safely. Preserve another destination's exports
   while it uploads. Bound temporary storage and make first seeding an explicit
   operation rather than letting it starve another nightly destination.

The implementation can still expose named systemd instances for each job; sharing
code does not require sharing locks, credentials, repository state, or failures.

## Placement and migration

Preserve current roles initially: each source pushes its own data directly to its
own offsite repository; Hoth receives Ferrix locally and can remain the trusted
maintenance host. Represent that placement generically, not with Ferrix-specific
units. Do not back up Ferrix's Borg repository as a substitute for its direct
BorgBase backup, and do not merge the two hosts' BorgBase repositories.

Hoth can monitor Ferrix independently. Hoth's own job needs the same local
failure/freshness reporting, with an external missed-backup safety net so a dead
Hoth is detectable. Configure BorgBase alerts for both repositories as a secondary
signal; repository modification alone is not proof of a completed archive.

Migration order:

1. Correct Hoth's now-confirmed obsolete/missing source declarations using the
   supplied mounts, including AFP Northwestern's confirmed `/mnt/backup1` path.
   Preserve both supplied Immich media locations and export its database; defer
   storage cleanup and v3 compatibility decisions to the separate upgrade task.
   Verify the newest usable
   archives at both existing destinations. Test an old Hoth file before changing
   repo credentials or archive naming. The user inventories application
   containers/exports and supplies sanitized output; agent SSH is not required.
2. Implement the shared module and tests without changing live jobs. Test Hoth
   and Ferrix evaluation, generated units, config validation, and credentials.
3. Migrate Hoth using the same repository identities, encryption, legacy archive
   filter, and active source coverage. Drop retired PhotoPrism declarations and
   introduce explicit Immich/Frigate exports without pruning historical archives
   during the initial rollout. Remove the legacy
   timer only when its replacement is ready; prevent duplicate schedulers.
4. Migrate Ferrix to the same engine/module without changing its repositories or
   invalidating the registered client key. Replace Ferrix-specific Hoth role
   generation and health helpers with generic declarations and temporary aliases
   where needed for existing operator commands.
5. Prove new successful backups to both destinations for each source, then enable
   matching retention and monitoring. Preserve legacy archive coverage separately
   when introducing a new successful-archive naming convention.
6. Remove obsolete helpers/declarations only after read-back and restore tests.
   Preserve Samba shares and their users; no SMB access to writable Borg internals.

## Acceptance criteria

- Both sources complete to both declared destinations and remain independently
  diagnosable through generated unit names and per-destination status.
- An unavailable local disk/remote destination does not prevent the other
  destination's attempt. Missing required mounts cannot produce false success.
- Failed exports, warnings, incomplete/checkpoint archives, and stale success
  records are correctly reported and cannot make external monitoring healthy.
- Database exports restore in disposable instances; known historical Hoth
  archives and newly completed archives remain readable after migration.
- Maintenance and full verification cannot race for the same repository.
- Email delivery and off-host missing-backup detection are exercised, not assumed.
- Both host builds, the shared backup tests, and flake checks pass before rollout.

Open facts: latest usable archive dates, database identity/export mechanism,
Frigate's configured DB path, existing export jobs, selected Frigate media,
and remote quota/seed duration. The observed missing-source failure and deployed
Immich/PostgreSQL/Frigate versions are no longer open questions. Remaining facts
require user-provided runtime evidence, not guesses during implementation.

Deferred to the separate Immich v3 task: detailed legacy-media reconciliation,
stable explicit storage layout, and version-specific upgrade/restore procedure.
Do not make those decisions a prerequisite for restoring Hoth's backups or
building the shared module; preserve both known media locations in the interim.
