# Ferrix Paseo mobile trial

## Scope and security

`hosts/ferrix/paseo.nix` adds `paseo-test.service` using the flake's pinned
`pkgs.paseo`. It runs as `mpfammatter`, not root or Inigo, so Pi uses the existing
personal configuration and provider login. No credentials are copied into Nix.

The service binds only Ferrix's Tailscale IPv4 address on port 6767. The firewall
opens that port only on `tailscale0`; the public Paseo relay is explicitly off.
Tailscale encrypts the direct connection. A separately generated daemon password
is also required. Anyone with that password and network access can operate agents
with the user's file access, so keep both the password and tailnet ACLs restricted.
The service disallows privilege escalation and makes system paths read-only,
while retaining a writable home and private temporary storage.

Trial state is isolated in `~/.paseo-test`, already covered by the personal-home
backup source. The launcher restores the declarative `config.json` on each start;
app-side changes to that file do not survive a restart. Sessions and the generated
password are retained. Dictation and voice mode are disabled to avoid automatic
speech-model downloads during this text-chat trial.

The custom `ask_questions` tool is excluded only in Paseo-launched Pi processes:
its terminal questionnaire does not work over RPC. Normal terminal Pi retains it.
For this trial, ask clarification questions in chat; adapting the questionnaire
is a separate change. Existing extensions are otherwise left enabled.

## Apply and connect

From the updated configuration checkout on Ferrix, as the administrator:

```sh
sudo nixos-rebuild switch --flake .#ferrix
systemctl status paseo-test --no-pager
journalctl -u paseo-test -n 50 --no-pager
tailscale ip -4
```

On the iPhone:

1. Connect Tailscale to the same tailnet.
2. In Paseo, add a host using a direct connection.
3. Use Ferrix's Tailscale IP and port `6767` (TLS off for this direct endpoint;
   the Tailscale tunnel provides encryption).
4. Enter the generated daemon password locally. As `mpfammatter`, read
   `~/.paseo-test/password` in a private terminal or local editor. Do not paste it
   into an agent chat or commit it.
5. Create a workspace under `/home/mpfammatter` and select the Pi provider.

For CLI diagnostics, keep the password out of command arguments and history:

```sh
export PASEO_HOME="$HOME/.paseo-test"
export PASEO_PASSWORD="$(< "$PASEO_HOME/password")"
paseo --host "$(tailscale ip -4):6767" provider ls
unset PASEO_PASSWORD
```

## Acceptance checks

Automated:

```sh
nix build .#checks.x86_64-linux.paseo-test --no-link -L
nix build .#nixosConfigurations.ferrix.config.system.build.toplevel --no-link
```

The check starts the actual packaged daemon in an isolated home, verifies HTTP
password enforcement, makes an authenticated WebSocket connection, and waits for
Pi provider availability. It makes no model requests and uses no personal login.
It also checks the service user, hardening, relay setting, firewall scope, and
absence of the old relay units and global extension declaration.

After activation, verify manually:

- A new terminal Pi session no longer loads remote-pi or prompts for its keychain.
- `paseo-test.service` is active and listens on the Tailscale IP only.
- The iPhone connects with the password and cannot connect without it.
- A Pi chat can answer a simple prompt using the existing provider login.
- Disconnect/reconnect the phone and verify the chat remains available.
- Add a second execution host separately if multi-host behavior needs testing.
- Do not claim custom Ask UI compatibility until an RPC fallback is implemented.

## Remote-pi retirement and rollback

The global npm extension declaration, managed remote-pi configuration files,
Ferrix relay container, and its Tailscale Serve unit are removed. Other machines
stop loading the shared extension after their own Home Manager activation.
Already-running Pi processes must be restarted.

No identity files, pairings, cached npm packages, chats, or relay data are deleted.
The retired `/var/lib/remote-pi-relay` remains a backup source deliberately; remove
it from the backup policy only when its retained data is intentionally retired.
The old Serve unit's stop action clears `svc:pi` during activation; inspect
`sudo tailscale serve status` if the old endpoint remains visible.

To stop the trial immediately:

```sh
sudo systemctl stop paseo-test
```

To remove it persistently, remove `./paseo.nix` from Ferrix's imports and rebuild.
Keep `~/.paseo-test` until its chats are no longer needed. No rollback requires
deleting identities or recovering credentials from a Nix store file.
