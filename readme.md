# Mixed Nix Configuration

A nix config with multiple hosts and multiple architectures

## Installation

### Nix-Darwin

Install nix from [determinate systems installer](https://github.com/DeterminateSystems/nix-installer)

clone repo and change into new directory

```sh
nix run darwin-rebuild -- switch --flake .#
```
