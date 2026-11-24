# Inigo in Zulip

Ferrix imports `hosts/ferrix/inigo-zulip.nix` through `inigo.nix`. This installs
an owner-only, text-message platform plugin into the existing Hermes gateway.
It does not create another agent profile or grant Inigo sudo or Docker access.

## Activation

Run the normal rebuild on Ferrix from the checkout containing these changes:

```sh
sudo nixos-rebuild switch --flake "path:$PWD#ferrix"
```

The `path:` form includes new files before they have been committed. Enter your
password only into the terminal's sudo prompt, never into a chat message.

Activation starts `inigo-zulip-provision.service` as root before the gateway.
It waits for Zulip's local HTTP endpoint, then creates or validates the generic
bot `inigo-bot@chat.mmjo.com`, named **Inigo**, owned by `michael@mmjo.com`.
The owner must already be an active human account in organization `mmjo`.
Provisioning refuses conflicting identities, changed keys, or an unreviewed
Zulip version. It never rotates an API key or changes an existing account.

The generated key remains root-owned, mode `0400`, in a private state directory.
Only `hermes-agent.service` receives it through systemd `LoadCredential`. It
never enters Git, the Nix store, application settings, or environment variables.
This uses generated host state, not a new SOPS entry; the bot database retains
its authoritative key and a rerun can recover a missing local copy.

Provisioning is a required gateway dependency. If it fails, the gateway will not
start, including its other messaging interfaces. The separate dashboard/backend
is not made dependent on bot provisioning. Diagnose identity or readiness errors
rather than bypassing the dependency with an unverified credential.

## Verify

```sh
systemctl is-active inigo-zulip-provision.service hermes-agent.service
journalctl -u inigo-zulip-provision.service -u hermes-agent.service -n 80 --no-pager
```

In Zulip, send **Inigo** a direct message from `michael@mmjo.com` and confirm a
reply. The plugin resolves your numeric user ID from the authenticated server.
It ignores channel messages, group DMs, messages from other users, and its own
messages. Outbound messages are also restricted to your one-to-one DM.

The initial integration is text-only: it does not download attachments or
backfill messages sent while disconnected. Send a new message after the gateway
is connected when checking delivery. No live delivery is implied by a build.

## Recovery

After fixing a transient startup issue:

```sh
sudo systemctl restart inigo-zulip-provision.service
sudo systemctl restart hermes-agent.service
```

The provisioning command is also installed as `inigo-zulip-provision` for an
administrator to run directly. It prints only public account metadata. Never run
its embedded container program separately: that private pipe carries the key.
Do not print credential files or remove a mismatched local key without checking
why it differs. Explicit administrator recovery is required after key rotation.

## Validation

```sh
nix build --no-link "path:$PWD#nixosConfigurations.ferrix.config.system.build.toplevel"
```

Both component packages run unit and installed-output checks during their Nix
builds. See the README files under `hosts/ferrix/inigo-zulip/` and
`hosts/ferrix/zulip-inigo-provision/` for implementation boundaries and sources.
