# Inigo SilverBullet plugin

A native Hermes directory plugin for SilverBullet 2.10's `/.fs` API. It runs in the existing Hermes process and uses only Python's standard library.

Tools:

- `silverbullet_list_pages`
- `silverbullet_search`
- `silverbullet_read`
- `silverbullet_create`
- `silverbullet_update`
- `silverbullet_append`
- `silverbullet_move`
- `silverbullet_soft_delete`
- `silverbullet_upload_file`

The Nix configuration fixes the loopback origin, configured MultiSpace prefixes, per-space path allowlists, and content/search/output limits. Tool arguments cannot supply endpoints or credentials. The API token is read from the `silverbullet-api-token` systemd credential loaded from the `inigo/silverbullet-api-token` SOPS secret.

Existing-page mutations require the exact `last_modified` value returned by `silverbullet_read`. Mutations are serialized within the Hermes process and writes are read back for verification. Moves copy and verify the destination, recheck the source, and only then delete the source. Soft deletion moves pages below `Trash/`; irreversible deletion requires `permanent=true` and is reserved for an explicit user request.

SilverBullet 2.10 does not return ETags or implement `If-Match` for `/.fs`. The version check therefore detects changes between the agent's read and its mutation, but cannot make the final check-to-write interval atomic against browser edits or another process.

The plugin registers the namespaced `inigo-silverbullet:silverbullet` skill and a short system-prompt hint telling Inigo when to load it.

## File and image uploads

`silverbullet_upload_file` accepts `space`, an absolute local `source_path`, and
an exact `destination` below `assets/`, including the filename and extension.
It transfers binary bytes without base64 in the model context, guesses the MIME
type from the destination, and reads the attachment back to verify byte equality.
The result includes a SHA-256 digest, URL, Markdown link, and an image embed when
applicable. Identical-file retries are idempotent; differing existing files are
refused rather than overwritten.

Sources must be regular files within `allowed_upload_roots`, with symlink targets
checked against those roots. Hidden source files and managed destination paths
are rejected. Uploads fail closed when no roots are configured. The ferrix
configuration allows only Hermes chat images and scratch artifacts, not credential
or configuration directories. `max_upload_bytes` defaults to and is capped at
20 MiB, independently of the text-page limit.

Upload destinations are checked before writing and use `If-None-Match: *` when
creating. Servers ignoring conditional headers still have the same external
check-to-write race documented above; use distinctive attachment names.

After rebuilding ferrix, start a fresh Hermes session to discover the new tool.
Only native tool calls should be used for actual note and attachment operations.

## Credential setup

Create a dedicated SilverBullet MultiSpace account token authorized only for the Personal and KSP spaces, then add it without committing plaintext:

```bash
sops secrets/secrets.yaml
```

Add the encrypted key at `inigo/silverbullet-api-token`. Activation will fail closed until the secret exists.

## Verification

```bash
nix build .#checks.x86_64-linux.inigo-silverbullet-plugin
nix build .#nixosConfigurations.ferrix.config.system.build.toplevel
```
