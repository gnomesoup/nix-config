# SilverBullet Pi extension

Native Pi tools for the SilverBullet 2.x `/.fs` API. The extension runs inside Pi and talks directly to the existing SilverBullet server; it does not start a daemon, MCP server, child process, or listening socket.

Tools:

- `silverbullet_search`: list or search user notes, with an in-process content cache.
- `silverbullet_read`: read a page or line range.
- `silverbullet_create`: create without overwriting.
- `silverbullet_append`: append or create.
- `silverbullet_update`: confirmed whole-page replacement, exact-text replacement, or deletion.

Security and safety properties:

- The immutable Nix-generated configuration determines the endpoint and optional token-file path.
- Projects and tool arguments cannot override the endpoint or token.
- Redirects are rejected, response and note sizes are bounded, and model-visible output is truncated.
- The bearer token is read directly by the Pi process and is never returned in tool output.
- `Library/`, `Repositories/`, `.client/`, and other dot-prefixed roots cannot be mutated.
- Whole-page replacement, exact-text replacement, and deletion require interactive confirmation and fail closed without UI support.
- Create and append operations are serialized per page within each Pi process, and writes are read back for verification.

SilverBullet 2.9.0 on ferrix does not return `ETag` headers. Consequently, neither this extension nor a sidecar can guarantee atomic conflict detection against a simultaneous browser edit or another Pi process. When a future server provides an `ETag`, the extension sends it through `If-Match` on updates.
