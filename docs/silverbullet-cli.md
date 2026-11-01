# Official SilverBullet CLI on Ferrix

Ferrix packages the unmodified upstream **sb 2.12.1** binary, pinned by release
URL and SHA-256. nixpkgs' `silverbullet-cli` is the older Go client, not this `sb`
filesystem client. This package does not replace or upgrade the server itself.

- Upstream documentation: <https://docs.silverbullet.md/CLI>
- Release: <https://github.com/silverbulletmd/silverbullet/releases/tag/2.12.1>
- Package source: `hosts/ferrix/silverbullet-cli/`
- Installation: `services.hermes-agent.extraPackages` on Ferrix only.

## Commands

`sb` is the upstream executable. `inigo-sb` is a credential-only launcher for its
filesystem commands; all file transfer, exact-edit, and revision semantics remain
upstream. Select Personal or KSP explicitly:

```sh
sb version
inigo-sb personal fs stat 'GSA.md' --json
inigo-sb ksp fs ls GSA --recursive --glob '*.md'
inigo-sb personal fs edit --help
```

The configured endpoints are Ferrix's loopback Personal root and `/ksp` space.
File paths are relative to that space and include extensions. Do not prefix KSP
filenames with `/ksp`.

## Credentials

The launcher reuses Inigo's existing dedicated MultiSpace account credential,
provided privately by systemd to both Hermes units. No new secret, SOPS recipient,
or account permission is required. No credential value is embedded in Nix source,
the Nix store, generated launch arguments, or generated environment variables.

For each invocation, the launcher:

1. Reads the protected systemd credential, enforcing ownership, regular-file,
   permissions, bounded size, and single-line checks. Group-read ACL masks are
   accepted only for the two known systemd unit credential directories.
2. Runs upstream `sb space add`, supplying name, configured URL, authentication
   method, and token over a private stdin pipe. No token command-line flag is used.
3. Confirms the connection uses token authentication and a private config file.
4. Runs the requested upstream filesystem command with that temporary config.
5. Removes the isolated config directory, including upstream's encryption key,
   on normal completion or handled failure.

The token is not placed in an environment variable. Upstream's encrypted config
and its key exist together in a private temporary directory during the command;
this is not protection from the owning process or root. Abrupt uncatchable
termination can leave that encrypted temporary state for scratch cleanup. The
launcher suppresses login output so future upstream diagnostics cannot echo a
credential. File-command output remains upstream output and must be treated as
potentially sensitive note content.

The launcher uses `CREDENTIALS_DIRECTORY` when inherited. Hermes terminal tools
can filter that variable, so it also checks the two known Hermes unit credential
directories. It fails closed outside the authorized service credential context;
it does not decrypt SOPS files or fall back to personal credentials. Do not copy
credentials into scratch to make an administrator shell invocation work.

## Transfer and editing discipline

- Use `fs read` raw redirected output for binaries, never JSON or model context.
- Use `fs write --create` for new targets. On an existing target, compare original
  and destination bytes; do not overwrite different content.
- Read back and compare bytes or SHA-256 before reporting a successful transfer.
- Save the opaque quoted `revision` from `fs stat --json` unchanged and use
  `--if-match` for replacements, source cleanup, and conditional deletions.
- Use upstream `fs edit --file` with exact old/new JSON blocks to modify mixed
  journals without reproducing unrelated sensitive content. Do not expose the
  surrounding page through a diff or debug output.
- `sb` has no cross-space copy/move or Trash operation. Orchestrate verified
  read/create/readback steps. Retain recoverable originals until cleanup is safe.
- `fs rm` is permanent. Use it only for an explicitly authorized deletion, after
  verified recovery copies where required. Never use unconditional overwrite or
  deletion to evade a conflict or denied approval.
- CLI mutations do not invoke the native plugin's automatic journal logger.
  Explicitly append and verify same-space daily activity entries. Routine native
  note tools still use their existing automatic logging; do not duplicate it.
- Respect protected managed paths, user scope, and personal/work separation.

Default upstream transfers are capped at 16 MiB; choose a bounded `--max-bytes`
when needed. A connection loss during a write requires readback before retrying.

## Validation and deployment

```sh
nix build --no-link "path:$PWD#checks.x86_64-linux.inigo-silverbullet-cli"
nix build --no-link "path:$PWD#checks.x86_64-linux.inigo-silverbullet-plugin"
nix build --no-link "path:$PWD#nixosConfigurations.ferrix.config.system.build.toplevel"
```

The CLI package runs credential-boundary unit tests and actual upstream client /
server integration tests with two isolated spaces and explicitly fake
credentials. Tests cover space isolation, binary byte preservation, create
conflicts, exact edits preserving unrelated CRLF bytes, revision conflicts, and
file deletion.
Install checks run the installed launcher, not only the source script.

An administrator must apply the normal Ferrix rebuild; this implementation does
not activate the host or migrate production notes. Start a fresh Hermes session
so the packaged shared skill documents the official CLI workflow. Confirm
read-only access to both spaces before resuming migrations. Validate conditional
writes against the deployed server before removing source data; successful
read-only access alone does not prove destructive-operation compatibility.

Self-updates are not declarative. Update the pinned release/hash and rebuild
instead of using `sb upgrade` or `sb upgrade-edge`.
