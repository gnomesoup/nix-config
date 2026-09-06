# Home Assistant MCP extension

Ferrix-only Pi extension for Home Assistant's official MCP server and focused automation/script configuration APIs.

Security properties:

- Reads its immutable endpoint and token-file path from the Nix-generated configuration.
- Never accepts endpoint overrides from projects, tool arguments, or environment variables.
- Restricts REST requests to `/api/` on the configured Home Assistant origin and rejects redirects.
- Requires real UI confirmation for every mutation; mutations are disabled in headless modes.
- Limits REST responses and tool output. Truncated Home Assistant data is not persisted to disk.
- Reads the bearer token from a user-owned sops-nix secret rather than exporting it to child processes.

The ferrix configuration explicitly permits HTTP for the current `http://onderon:8123` endpoint. Prefer HTTPS before using this across an untrusted network.
