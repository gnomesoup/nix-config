# SilverBullet agent activity journal

## Ownership and scope

`agents/skills/silverbullet/` is the canonical skill bundle for Pi and Hermes.
The body contains shared note and daily-journal policy; `references/pi.md` and
`references/hermes.md` document the different native tool contracts.

Ferrix installs this directory into Pi through Home Manager and copies it into
the Hermes plugin package. Change the canonical bundle, not an installed copy.
The legacy Hermes `silverbullet-journal-links` skill is deployed as a compatibility
instruction, not a second journaling policy. Existing accounts, credentials,
spaces, endpoint restrictions, and deployment scope remain unchanged.

## Write contract

Non-journal mutations require a brief `change_summary`. The native integration
records a link and summary in `Journal/YYYY-MM-DD.md` in the same space, using
`America/New_York` at the time of the operation. Existing journal text is preserved.
Do not manually add another activity entry after an automatically logged write.

Read-only operations, denied approvals, failed mutations, and unchanged content
do not create entries. Journal-page edits are exempt to prevent recursion.
Moves and removals are described explicitly; a deletion is not represented only
by a broken link. Hermes attachment uploads also have their own activity record;
embedding the uploaded attachment into a note is a separate verified operation.

Writes to the note and journal are separate operations, not an atomic transaction.
A successful note write with journal failure is partial completion. Both native
integrations expose `silverbullet_journal_retry`; pass its returned retry payload
unchanged to recover only the missing journal entry. Preserve the original date
and operation identifier. Persisted entry markers make journal retries idempotent
across process restarts; markers are bookkeeping, not an authorization mechanism.
The adapters document the exact result fields and retry arguments.

This logs agent writes only. It does not watch browser or Nvim edits. Server-side
atomic conditional writes and cross-process locking are not available, so external
concurrent edits remain a last-writer-wins risk. Read-back verification and local
serialization reduce that risk but do not remove it.

## Verification

From the repository root, run the native suites and package checks:

```sh
(cd hosts/ferrix/inigo-silverbullet && python3 -m unittest discover -v)
nix build --no-link "path:$PWD#checks.x86_64-linux.inigo-silverbullet-plugin"
nix build --no-link "path:$PWD#checks.x86_64-linux.silverbullet-pi-extension"
nix build --no-link "path:$PWD#nixosConfigurations.ferrix.config.system.build.toplevel"
```

The package checks exercise a local mock HTTP server; they do not mutate real
notes. The Hermes package also tests the shared skill bundle and its adapter
references. Use a path flake while additions are untracked; do not stage files
just to make Nix include them.

## Deployment

Builds do not activate configuration. After review and authorized Git distribution,
an administrator applies the Ferrix configuration with its normal rebuild flow.
Restart/reload Pi and start a fresh Hermes session to discover the updated schemas,
retry tool, and skill bundle. Do not use a stale session's tool definitions.

In each agent and space, create a disposable test note, edit it, and read the note
and matching journal. Check that the journal has the expected link and brief
summary and that a journal-only edit does not generate recursive activity.
Delete test notes only with explicit approval; cleanup is also a logged change.
Do not claim live deployment from package tests or a successful system build.
