# Mixed Nix Configuration

A nix config with multiple hosts and multiple architectures

## Installation

### Nix-Darwin

Install nix from [determinate systems installer](https://github.com/DeterminateSystems/nix-installer)

clone repo and change into new directory

```sh
nix run darwin-rebuild -- switch --flake .#
```

## Home Manager

Linux and macOS use different apply paths in this repo:

- Linux uses standalone Home Manager outputs for user-level changes.
- macOS uses `nix-darwin` as the authoritative apply path, including Home Manager-managed packages like Neovim.

Use these commands for day-to-day applies:

```sh
apply

# Linux equivalent
nix run github:nix-community/home-manager -- switch --flake path:$PWD#mpfammatter-linux -b backup

# macOS equivalent
sudo darwin-rebuild switch --flake path:$PWD#$(scutil --get LocalHostName)
```

Using `path:$PWD` makes Nix evaluate the working tree directly, so local untracked changes are included. After files are committed to Git, `.#...` also works again.

If you want the `home-manager` command installed permanently on Linux, run:

```sh
nix profile install github:nix-community/home-manager
```

The `apply` alias is the recommended cross-platform entrypoint. `hms` still works, but on macOS it now dispatches to `darwin-rebuild` so packages and generated config stay aligned.

On macOS, `apply`, `hms`, and `drs` all go through `darwin-rebuild`, so Neovim binaries, plugin packs, and generated config stay in sync.

Use a full rebuild when changing host modules, services, users, boot settings, or other system-level options.
