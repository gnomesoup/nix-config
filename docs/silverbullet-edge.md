# SilverBullet edge on Ferrix

Ferrix uses the upstream prebuilt Linux x86_64 server from commit
`dbb715b298e53f0daf6424de5ab3f627e1f77f0c`, not nixpkgs' stable server.
The normal NixOS rebuild downloads and installs that binary; it does not compile
SilverBullet or automatically update to a newer edge build.

## Durable archive

The original ZIP, upstream license, and changelog are archived in this repository's
immutable GitHub release:

<https://github.com/gnomesoup/nix-config/releases/tag/silverbullet-edge-dbb715b298e5>

The ZIP is unchanged from upstream. Its hash is pinned in
`hosts/ferrix/silverbullet-edge/package.nix`. Repository release immutability is
enabled; updates must use new release tags, never replace existing assets.

To update, download the desired upstream edge asset, verify it against the
upstream release's SHA-256 digest, and record the upstream commit and version.
Create a new draft release with its commit-qualified tag, ZIP, license, and
changelog. Verify the attachments, publish it, and confirm `immutable: true`.
Update the package URL, hash, version, upstream revision, and version check.
Keep old releases available for rebuilds and rollbacks.

## Search and Silversearch retirement

Built-in full-text search indexes Markdown on the server. In Ferrix's multi-space
mode the persistent indexes live under `/var/lib/silverbullet/search/indexes/`.
Semantic search is not enabled by this configuration.

The managed-file service removes `_plug/silversearch.plug.js` from both Personal
and KSP through the authenticated API and verifies absence. This retirement is
idempotent; merely dropping the old sync would leave the installed plug active.
Other plugins and page contents are unchanged. Browser-local Silversearch cache
entries are not deleted; they are no longer used after the plug is unloaded.

Before first activation, ensure there is a recoverable backup of SilverBullet's
complete data directory. Edge is a development build; a Nix generation rollback
alone is not a database backup or proof that an older server can read newer data.
After activation, reload the browser and use the built-in search command.

## Verification

Use a path flake while new files are untracked:

```sh
nix build --no-link "path:$PWD#checks.x86_64-linux.silverbullet-edge"
nix build --no-link "path:$PWD#checks.x86_64-linux.silverbullet-plug-sync"
nix build --no-link "path:$PWD#checks.x86_64-linux.silverbullet-search-deployment"
nix build --no-link "path:$PWD#nixosConfigurations.ferrix.config.system.build.toplevel"
```

The package checks the installed executable's exact bytes and version, starts an
isolated fixture server, searches page contents, checks on-disk index creation
and survival across restart, and tests plugin removal against the real API.
The sync tests additionally cover both spaces, idempotence, failure redaction,
redirect rejection, token permissions, and verification of deletion.
The MultiSpace fixture starts from the pinned stable server's setup output and
checks root and `/ksp` routes, existing API tokens, search isolation, default
on-disk index storage, retirement, and restart. The deployment check executes the
evaluated wrapper with harmless stand-ins and proves a failed retirement cannot
be masked by subsequent successful sync commands.

Build success does not activate Ferrix. An administrator must rebuild and check
`silverbullet.service` and `silverbullet-plug-sync.service` afterwards.
