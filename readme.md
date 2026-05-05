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

## Local overlay

This repo defines a small local nixpkgs overlay in `flake.nix`.

Why we did this:

- `pi-coding-agent` is packaged locally under `pkgs/pi-coding-agent.nix` and is not being pulled directly from upstream nixpkgs.
- The overlay makes that package available through `pkgs` everywhere we use it: standalone Home Manager on Linux, NixOS hosts, and nix-darwin hosts.
- This keeps package resolution consistent across hosts and avoids repeating `callPackage ./pkgs/pi-coding-agent.nix { }` in multiple module trees.
- It also exposes the package as a normal package in the flake outputs, which makes ad hoc builds and debugging easier.

In short: the overlay is the shared, declarative place where repo-local packages are added to the package set for every system.

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

## WezTerm

WezTerm is managed by Home Manager in `users/modules/wezterm.nix`. See [the WezTerm cheatsheet](docs/wezterm-cheatsheet.md) for leader bindings and workspace behavior.

### WezTerm on Windows

The Linux Home Manager profile exports a Windows-ready WezTerm config to:

```sh
~/.local/share/wezterm-windows
```

Apply the Linux Home Manager config to refresh that export:

```sh
nix run github:nix-community/home-manager -- switch --flake path:$PWD#mpfammatter-linux -b backup
```

This copies `wezterm.lua` and the color scheme files into the export directory.

Windows WezTerm will prefer `%USERPROFILE%\.wezterm.lua` if that file exists. If Windows is still using an old standalone config, replace it with a link to the WSL export from PowerShell:

```powershell
if (Test-Path "$env:USERPROFILE\.wezterm.lua") {
  Rename-Item "$env:USERPROFILE\.wezterm.lua" ".wezterm.lua.old"
}
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config" | Out-Null
cmd /c mklink /D "%USERPROFILE%\.config\wezterm" "\\wsl.localhost\NixOS\home\mpfammatter\.local\share\wezterm-windows"
```

Adjust `NixOS` if the WSL distro name differs. After linking, restart Windows WezTerm or reload its config.

## Espanso on Windows

The Linux Home Manager profile exports a Windows-ready Espanso config to:

```sh
~/.local/share/espanso-windows
```

Apply the Linux Home Manager config to refresh that export:

```sh
nix run github:nix-community/home-manager -- switch --flake path:$PWD#mpfammatter-linux -b backup
```

That export includes the public match files and the rendered `private.yml`, so treat it as secret material.

### Link Windows Espanso to the exported config

This part is manual and only needs to be done once on Windows.

1. Stop Espanso on Windows.
2. Back up or remove `%AppData%\espanso`.
3. Find your WSL distro name with:

```powershell
wsl -l
```

4. Create a directory symlink pointing Espanso at the WSL export:

```bat
mklink /D "%AppData%\espanso" "\\wsl.localhost\<DistroName>\home\mpfammatter\.local\share\espanso-windows"
```

Use a directory symlink (`/D`), not a junction (`/J`), because `\\wsl$\...` is a UNC path.

Depending on your Windows settings, creating the symlink may require an elevated shell or Developer Mode.

## PowerToys on Windows (jedha)

The `jedha` Home Manager profile exports managed PowerToys files to:

```sh
~/.local/share/powertoys-windows
```

Currently this manages the PowerToys Keyboard Manager profile that remaps `Win+A/C/P/V/X` to `Ctrl+A/C/P/V/X`.

Apply the `jedha` NixOS config to refresh that export:

```sh
sudo nixos-rebuild switch --flake .#jedha
```

Link the Windows PowerToys Keyboard Manager directory to the WSL export from `cmd` after quitting PowerToys:

```bat
ren "%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager" "Keyboard Manager.old"
mklink /D "%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager" "\\wsl.localhost\NixOS\home\mpfammatter\.local\share\powertoys-windows\Keyboard Manager"
```

Use a directory symlink (`/D`), not a junction (`/J`), because the target is a UNC path. Avoid linking the whole PowerToys settings directory; it contains mutable runtime state and version-specific files.
