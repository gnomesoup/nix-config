# Inigo on ferrix

Inigo currently runs on Hermes Agent as a native NixOS service with the upstream full dependency package. The platform-neutral service identity and state root are `inigo` and `/var/lib/inigo`; Hermes-specific mutable state remains under `/var/lib/inigo/.hermes`.

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

The full package is large, but the build can reuse the paths already produced during configuration validation. On the first activation after adopting the Inigo identity, the activation script copies missing mutable state into `/var/lib/inigo`, retains the old tree at `/var/lib/hermes.pre-inigo`, and makes `/var/lib/hermes` a compatibility symlink. The symlink lets existing sessions with a persisted pre-migration working directory resume safely.

## Assistant capabilities

Reusable credentials live under the platform-neutral `inigo` SOPS namespace. This includes the Home Assistant token, the dedicated SilverBullet MultiSpace API token, and the Proton Mail Bridge email, username, and password. Hermes-specific dashboard and API credentials remain under `hermes` because their format belongs to the current runtime.

The Nix-packaged plugin in `hosts/ferrix/inigo-silverbullet/` registers native page-list, search, read, create, update, append, move, and soft-delete tools. It calls the loopback-only SilverBullet `/.fs` API from the existing Hermes processes with Python's standard library. The `inigo/silverbullet-api-token` SOPS secret is loaded into both Hermes units as a private systemd credential rather than copied into the Nix store or `.env`.

Create a dedicated SilverBullet account token authorized for Personal and KSP, then add the encrypted key with `sops secrets/secrets.yaml` before activation. Existing-page mutations require the `last_modified` value from a prior read; soft deletion moves pages below `Trash/` unless irreversible deletion was explicitly requested. See `hosts/ferrix/inigo-silverbullet/README.md` for the API and concurrency limitations.

## Authenticate OpenAI Codex

The model is pinned declaratively to `openai-codex/gpt-5.6-sol`. OpenAI workspace policy disables the device-code flow implemented by Hermes, while Pi's browser OAuth flow remains allowed. The initial Hermes credential was therefore imported locally from Pi's OAuth store without printing or committing token material.

Hermes stores and refreshes its imported credential in `/var/lib/inigo/.hermes/auth.json`; NixOS rebuilds preserve this mutable file. If it needs reauthorization, first refresh Pi's login and repeat the controlled import, or ask the OpenAI workspace administrator to enable Codex device-code authentication. Never place the OAuth token in Nix configuration or SOPS because Hermes must rotate it at runtime.

The `mpfammatter` account is added to the `inigo` group. Start a new login session after activation before using the system `hermes` CLI directly.

## Operations

```bash
systemctl status hermes-agent hermes-backend
journalctl -u hermes-agent -u hermes-backend -f
hermes status
hermes doctor
```

## Chat appearance

Inigo's `spacemacs-dark` skin is preserved declaratively in `hosts/ferrix/inigo-spacemacs-dark.yaml` and selected through `display.skin`. It is the default for the embedded dashboard Chat TUI and other Hermes terminal surfaces.

Hermes 0.21.2 hard-codes the dashboard Chat terminal font and responsive sizes in its web frontend rather than exposing configuration keys. `hosts/ferrix/hermes-chat-source-code-pro.patch` therefore changes only the embedded Chat terminal to locally served Source Code Pro and uses 12 px on phones, 14 px on tablets, and 16 px on desktop widths. The upstream frontend is patched before Vite creates content-hashed assets, so browsers receive the correct files without stale immutable-cache collisions. An incompatible future Hermes update will fail the patch during the Nix build rather than silently reverting the customization.

Inigo uses an isolated writable workspace at `/var/lib/inigo/workspace`; it cannot modify `/home/mpfammatter/nix-config` in this initial deployment.

Configuration is managed in `hosts/ferrix/inigo.nix`. Values declared there override dashboard edits after a rebuild, and the SOPS template recreates `.env`; make durable configuration changes in Nix rather than only through the dashboard.
