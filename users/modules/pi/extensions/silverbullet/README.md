# SilverBullet Pi extension

Native Pi tools for the SilverBullet 2.10 `/.fs` API, including path-bound MultiSpace deployments. The extension runs inside Pi and talks directly to the configured server; it does not start a daemon, MCP server, child process, or listening socket.

Every tool accepts an optional `space`. The immutable configuration supplies the allowed names, labels, and URL prefixes; omitting `space` uses `defaultSpace`. On ferrix the choices are `personal` (Personal at `/`, the default) and `ksp` (KSP at `/ksp`). Results, mutation confirmations, and result details identify the selected space.

Tools:

- `silverbullet_search`: list or search user notes, with an in-process, per-space content cache.
- `silverbullet_read`: read a page or line range.
- `silverbullet_create`: create without overwriting.
- `silverbullet_append`: append or create.
- `silverbullet_update`: confirmed whole-page replacement, exact-text replacement, or deletion.

Configuration shape:

```json
{
  "baseUrl": "http://127.0.0.1:3000",
  "allowInsecureHttp": true,
  "tokenFile": "/run/secrets/silverbullet/pi-api-token",
  "defaultSpace": "personal",
  "spaces": {
    "personal": { "label": "Personal", "path": "/" },
    "ksp": { "label": "KSP", "path": "/ksp" }
  }
}
```

`baseUrl` must be an HTTP(S) origin without credentials or a path. Space paths must be canonical, literal URL prefixes. Tool arguments can select only configured space names and can never provide an endpoint or URL prefix.

## Authentication

SilverBullet 2.10 MultiSpace does not use `SB_AUTH_TOKEN`. Create a per-account API token in the authenticated Space Manager at `/.spaces`; the account must be authorized for every selected space. Store the token only in the sops secret `silverbullet/pi-api-token`. The Nix-generated configuration contains only the runtime secret path. SilverBullet expects the token as `Authorization: Bearer …` and the extension never includes it in output or errors.

The token file must be absolute, regular, non-empty, and inaccessible to group/other users. Restart Pi after rotating it because configuration and credentials are read once per extension load.

## Security and safety properties

- The immutable Nix-generated configuration determines the origin, space prefixes, default space, and token-file path.
- Projects and tool arguments cannot override endpoints, prefixes, or credentials.
- Redirects are rejected, response and note sizes are bounded, and model-visible output is truncated.
- The bearer token is read directly by the Pi process and is never returned in tool output.
- `Library/`, `Repositories/`, `.client/`, and other dot-prefixed roots cannot be mutated.
- Whole-page replacement, exact-text replacement, and deletion require interactive confirmation that names the target space, and fail closed without UI support.
- Create and append operations are serialized per page and per space within each Pi process, and writes are read back from the same space for verification.

SilverBullet 2.10.0 does not return `ETag` headers or implement `If-Match` for `/.fs` writes. Therefore neither this extension nor a sidecar can guarantee atomic conflict detection against a simultaneous browser edit or another Pi process. The extension preserves metadata, serializes in-process changes, and verifies writes, but concurrent external edits remain a last-writer-wins risk.

Authoritative references are pinned to the 2.10.0 tag:

- [`docs/Authentication.md`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/docs/Authentication.md)
- [`docs/Space Manager.md`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/docs/Space%20Manager.md)
- [`server/src/multi/dispatch.rs`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/server/src/multi/dispatch.rs)
- [`server/src/handlers/fs.rs`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/server/src/handlers/fs.rs)
