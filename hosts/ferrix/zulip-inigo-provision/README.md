# Inigo Zulip provisioning (Ferrix)

`package.nix` exposes `inigo-zulip-provision`. Run it **as root**, without
arguments, either from a root oneshot unit or from an administrator's shell.
`--help` is read-only; unrecognized arguments are rejected. The command does
not restart services, activate Nix configurations, or request a password.

## Fixed identity and behavior

- Organization: root realm `string_id=""`, URL `https://chat.mmjo.com`.
  `mmjo` is its display name, not the database lookup key.
- Existing active human owner: `michael@mmjo.com` (looked up at runtime in that
  organization, never assumed to exist and never created by this script).
- Short name `inigo`, full name `Inigo`, generic bot type `1`, member role `400`.
- Exact bot address: **`inigo-bot@chat.mmjo.com`**. The script derives this using
  `realm.get_bot_domain()` as the Zulip creation view does, then verifies the
  exact expected address. It refuses a different realm URL/domain.
- Existing accounts are reused only when their bot identity, owner, active
  status, generic type, member role, and absence of special administrative
  flags all match. No existing account is renamed, reassigned, reactivated,
  promoted, or converted into a bot. Existing bot settings are preserved.
- Missing bots are created with `do_create_user` and `notify_created_bot`, after
  Zulip's name and owner-permission checks. No password is set. Creation uses
  Zulip's normal action/audit/event machinery, not raw ORM inserts.
- Existing API keys are only read, never regenerated. A mismatch against an
  already-persisted credential is an error, not permission to overwrite it.

The command uses the deployment's exact Compose project/file/service:
`docker compose --project-name zulip -f /etc/zulip/compose.yaml exec -T
--user root zulip su zulip -c ...`. The management shell runs as **zulip**, not
root, at `/home/zulip/deployments/current/manage.py`. Program source is sent on
stdin; no credentials are put in command-line arguments or Nix expressions.
The container code refuses unreviewed versions other than Zulip **11.6**.

## Credential boundary

The container emits a private JSON response to the host's captured pipe.
Neither that response nor the captured application stdout/stderr is forwarded
to the terminal or journal. Host stdout contains only fixed-identity public
JSON metadata: status (`created`/`existing`), realm, site, bot email, owner email,
and bot user ID. Failures produce a generic, nonsecret diagnostic and a nonzero
exit status. Do not run the container program manually to inspect its output.

The host atomically publishes `/var/lib/inigo-zulip/api-key`, root-owned with
mode `0400`, inside a root-owned `0700` directory. Publication uses a flushed,
fsynced private temporary file and a no-clobber hard link; matching reruns leave
the credential inode untouched. A private filesystem lock prevents concurrent
host runs, and a database realm-row lock serializes the application operation.
Symlinks, multiply-linked files, nonregular files, incorrect ownership/modes,
and malformed local credentials are refused before invoking Docker.

Keep this directory outside the Nix store and source tree. A root unit may use
`StateDirectory=inigo-zulip` and `StateDirectoryMode=0700`, then the assistant
service can consume the existing file through systemd `LoadCredential`. No SOPS
migration is required to use this design. Never add this plaintext key to Git,
Nix string values, environment variables, command arguments, or console logs.

A database commit and a host filesystem publication cannot be one transaction.
If creation succeeds but the process fails before publishing the file, the next
run safely retrieves the same bot/key. If an administrator independently rotates
the bot key, a stale local credential is intentionally preserved and provisioning
fails; reconcile the designated credential explicitly as an administrator rather
than teaching this command to rotate or overwrite it. A crash during publication
can leave a private `.api-key-*` temporary file; multiple links on the destination
are deliberately fail-closed and require administrator inspection.

## Nix integration and startup

Instantiate with `pkgs.callPackage ./zulip-inigo-provision/package.nix { }` from
`hosts/ferrix`. The root unit's `ExecStart` should run that package's
`bin/inigo-zulip-provision` before the assistant starts. It needs the root Docker
socket, the running Compose deployment, and write access to its state directory.
Do not grant the assistant user Docker or sudo access.

`After=zulip.service` alone does not guarantee application/database readiness:
`zulip.service` uses Compose `up -d`. Arrange bounded unit retries or explicit
readiness handling in the calling unit. This script makes one bounded Docker
attempt (180-second timeout), fails closed on startup errors, and never restarts
anything itself. Do not skip provisioning merely because the key file exists;
reruns also verify the current application identity/key.

## Verification and limits

```console
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s hosts/ferrix/zulip-inigo-provision -v
```

The derivation runs the tests in both `checkPhase` and `installCheckPhase` and
executes the installed CLI as an actual unprivileged user. Tests use real local
files, permissions, symlinks, FIFOs, hard links, and advisory locks; only the
Docker subprocess boundary is mocked. Fixtures contain dummy keys, not live
credentials. The embedded Zulip program is syntax-checked by the tests, and its
calls were checked against the pinned upstream source. These are not live
Zulip/database integration tests. Live owner existence, creation, event delivery,
and root credential ownership still require an administrator-run invocation.

## Primary references reviewed

- Zulip 11.6 management-shell guidance (use action functions for cache, event,
  and audit correctness):
  https://github.com/zulip/zulip/blob/11.6/docs/production/management-commands.md
- Exact creation view: `add_bot_backend`, including `short_name + '-bot'`,
  `realm.get_bot_domain()`, permission checks, `do_create_user`, and
  `notify_created_bot`:
  https://github.com/zulip/zulip/blob/11.6/zerver/views/users.py
- Exact action signatures and bot notification:
  https://github.com/zulip/zulip/blob/11.6/zerver/actions/create_user.py
- Owner permission and bot-name checks:
  https://github.com/zulip/zulip/blob/11.6/zerver/lib/users.py
- Bot domain derivation (valid realm host first), realm URL, user fields and
  numeric constants:
  https://github.com/zulip/zulip/blob/11.6/zerver/models/realms.py
  https://github.com/zulip/zulip/blob/11.6/zerver/models/users.py
- Existing `create_user` management command has no generic-bot provisioning
  interface; it is not used:
  https://github.com/zulip/zulip/blob/11.6/zerver/management/commands/create_user.py
- Exact image source/version and `su zulip -c` deployment path:
  https://github.com/zulip/docker-zulip/blob/ghcr-11.6-1/Dockerfile
  https://github.com/zulip/docker-zulip/blob/ghcr-11.6-1/entrypoint.sh
- Generic bots have normal user-like access, unlike incoming-webhook bots:
  https://zulip.com/help/bots-overview

The creation view is an internal server API; do not assume a stable public
`add-bot` REST endpoint. Re-review these internal functions when upgrading Zulip.
