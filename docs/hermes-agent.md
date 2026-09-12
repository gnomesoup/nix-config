# Hermes Agent on ferrix

Hermes Agent runs as a native NixOS service with the upstream full dependency package. Its gateway, API, dashboard, sessions, memory, credentials, and workspace persist under `/var/lib/hermes`.

## Tailnet endpoints

- Dashboard: <http://ferrix.tailbb897.ts.net:9119>
- Agent API: `http://ferrix.tailbb897.ts.net:8642/v1`
- API health: <http://ferrix.tailbb897.ts.net:8642/health>

The NixOS firewall exposes ports 9119 and 8642 only on `tailscale0`. The dashboard uses username `mpfammatter` and an encrypted password. The API requires a bearer token.

Retrieve either credential locally without committing plaintext:

```bash
sops decrypt --extract '["hermes"]["dashboard-password"]' secrets/secrets.yaml
sops decrypt --extract '["hermes"]["api-server-key"]' secrets/secrets.yaml
```

## Activate

```bash
sudo nixos-rebuild switch --flake ~/nix-config#ferrix
```

The full package is large, but the build can reuse the paths already produced during configuration validation.

## Authenticate OpenAI Codex

The model is pinned declaratively to `openai-codex/gpt-5.6-sol`. After the first activation, complete the one-time device-code login as the service account:

```bash
sudo -u hermes \
  HOME=/var/lib/hermes \
  HERMES_HOME=/var/lib/hermes/.hermes \
  /run/current-system/sw/bin/hermes auth add openai-codex
```

Hermes stores and refreshes the resulting OAuth credentials in `/var/lib/hermes/.hermes/auth.json`; NixOS rebuilds preserve this file.

The `mpfammatter` account is added to the `hermes` group. Start a new login session after activation before using the system `hermes` CLI directly.

## Operations

```bash
systemctl status hermes-agent hermes-backend
journalctl -u hermes-agent -u hermes-backend -f
hermes status
hermes doctor
```

Hermes uses an isolated writable workspace at `/var/lib/hermes/workspace`; it cannot modify `/home/mpfammatter/nix-config` in this initial deployment.

Configuration is managed in `hosts/ferrix/hermes-agent.nix`. Values declared there override dashboard edits after a rebuild, and the SOPS template recreates `.env`; make durable configuration changes in Nix rather than only through the dashboard.
