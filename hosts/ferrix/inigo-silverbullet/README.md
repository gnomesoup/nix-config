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

The Nix configuration fixes the loopback origin, configured MultiSpace prefixes, per-space path allowlists, and content/search/output limits. Tool arguments cannot supply endpoints or credentials. The API token is read from the `silverbullet-api-token` systemd credential loaded from the `inigo/silverbullet-api-token` SOPS secret.

Existing-page mutations require the exact `last_modified` value returned by `silverbullet_read`. Mutations are serialized within the Hermes process and writes are read back for verification. Moves copy and verify the destination, recheck the source, and only then delete the source. Soft deletion moves pages below `Trash/`; irreversible deletion requires `permanent=true` and is reserved for an explicit user request.

SilverBullet 2.10 does not return ETags or implement `If-Match` for `/.fs`. The version check therefore detects changes between the agent's read and its mutation, but cannot make the final check-to-write interval atomic against browser edits or another process.

The plugin registers the namespaced `inigo-silverbullet:silverbullet` skill and a short system-prompt hint telling Inigo when to load it.

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
