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

Home-manager is available in two modes:

- Full system rebuilds still work through `nixos-rebuild` and `darwin-rebuild`.
- User-only changes can be applied independently with standalone flake outputs.

Use the standalone outputs for home-manager-only changes:

```sh
nix run github:nix-community/home-manager -- switch --flake path:$PWD#mpfammatter-linux -b backup
nix run github:nix-community/home-manager -- switch --flake path:$PWD#mpfammatter-darwin -b backup
```

Using `path:$PWD` makes Nix evaluate the working tree directly, so local untracked changes are included. After files are committed to Git, `.#...` also works again.

If you want the `home-manager` command installed permanently, run:

```sh
nix profile install github:nix-community/home-manager
```

The `hms` zsh alias selects the correct profile automatically on Linux vs macOS and does not require a separate install.

Use a full rebuild when changing host modules, services, users, boot settings, or other system-level options.
