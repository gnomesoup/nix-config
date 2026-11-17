# Exegol: replace Determinate with nix-darwin-managed upstream Nix

This is a clean reinstall, not a store-preserving migration. The user approved
re-downloading packages and losing the old Nix store and rollback generations.
No host removal or installation has been performed by Inigo.

## Preconditions

- Publish and pull the migration commit before uninstalling. Confirm the Exegol
  checkout has `nix.enable = true` in `hosts/exegol/default.nix`.
- Back up personal files, application state, credentials, and SSH/age identities.
  A flake recreates declared software/configuration, not those private data.
- Keep the checkout and backups outside `/nix`. Verify private backups are not
  readable by other users and are not committed or pasted into chat.
- Use locally connected input devices. Nix-managed Input Leap will stop when its
  installation disappears. Keep Terminal open throughout the migration.
- Expect Nix-managed apps, shell integrations, and services to be temporarily
  unavailable. Do not run the normal `apply` alias before removing Determinate.

## Removal and bootstrap

1. Save `/nix/receipt.json`, `/nix/nix-installer`, and `/etc/nix` to a private
   backup directory outside `/nix`. These aid diagnosis if removal fails; they
   are not a complete backup of the old store.
2. Open a clean system shell with `/bin/zsh -f` to avoid depending on Nix-managed
   shell plugins during removal.
3. Run the existing installer interactively:

   ```sh
   sudo /nix/nix-installer uninstall --explain
   ```

   Review its plan and confirm the approved clean removal. If it fails, stop
   and preserve its error. Do not manually delete the volume or build users.
4. Check that `determinate-nixd` and its system launch services are gone. The
   failed upgrade replaced its client, so residual components are possible.
   If any remain, stop and inspect them rather than bypassing nix-darwin's guard.
5. Bootstrap using the installer currently recommended by nix-darwin:

   ```sh
   /usr/bin/curl -fsSL https://install.lix.systems/lix -o "$HOME/lix-installer.sh"
   /bin/sh "$HOME/lix-installer.sh" install
   ```

   Review the downloaded installer before executing it. Lix is the bootstrap
   interpreter here; nix-darwin will select upstream Nix on activation. Follow
   installer instructions and stop on errors rather than layering installers.

## Restore declarative management

Use the absolute bootstrap executable because the old shell may retain stale
paths or functions. The `--inputs-from` flag resolves nix-darwin from the local
flake's locked input rather than selecting a new upstream revision.

```sh
sudo /nix/var/nix/profiles/default/bin/nix \
  --extra-experimental-features 'nix-command flakes' \
  run --inputs-from "$HOME/nix-config" nix-darwin#darwin-rebuild -- \
  switch --flake "path:$HOME/nix-config#exegol"
```

Do not run this activation while Determinate components remain installed.
After successful activation, open a new terminal and verify:

```sh
command nix --version
type -a determinate-nixd
alias garbage
sudo launchctl list | grep -Ei 'nix|determinate'
```

Expected: upstream Nix rather than Determinate or the bootstrap Lix interpreter;
no Determinate executable or services; and `garbage` runs collection only, with
no store optimisation. Check that Input Leap and other configured services work.
A successful local evaluation is not a verified Exegol rebuild or migration.

## References

- nix-darwin's current README recommends the Lix installer as a bootstrap and
  documents upstream Nix as its default managed interpreter.
- Official installer instructions: `https://lix.systems/install/`.
- Exegol's installed Determinate installer 3.0.0 supports the interactive
  `uninstall --explain` command; its help exposes no keep-store flag.
