# Configuration wiring diagram

This repository has one entry point, `flake.nix`. It combines upstream flakes,
repo-local modules, and host/user profiles into NixOS, nix-darwin, and standalone
Home Manager outputs.

## Top-level wiring

```mermaid
flowchart LR
  classDef input fill:#e8f1ff,stroke:#3973ac,color:#111
  classDef entry fill:#fff4cc,stroke:#a67c00,color:#111
  classDef output fill:#e9f7e9,stroke:#3b7d3b,color:#111
  classDef local fill:#f5e9ff,stroke:#7952a3,color:#111

  subgraph Inputs[Upstream inputs]
    nixpkgs["nixpkgs"]
    darwin["nix-darwin"]
    hm["home-manager"]
    sops["sops-nix"]
    wsl["nixos-wsl"]
    nixvim["kickstart-nixvim"]
    freenet["freenet-core"]
    pimonorepo["pi-mono source"]
  end

  flake["flake.nix"]
  overlay["overlays.default"]
  pipkg["pkgs/pi-coding-agent.nix"]

  subgraph NixOS[NixOS outputs]
    hoth["hoth"]
    ferrix["ferrix"]
    nixvm["nixvm"]
    jedha["jedha · WSL"]
  end

  subgraph Darwin[nix-darwin outputs]
    tests["Tests-Virtual-Machine"]
    coruscant["Coruscant"]
    exegol["exegol"]
  end

  standalone["Home Manager<br/>mpfammatter-linux"]
  formatter["formatter · all supported systems"]
  pioutput["package/app<br/>pi-coding-agent + updater"]

  nixpkgs --> flake
  darwin --> flake
  hm --> flake
  sops --> flake
  wsl --> flake
  nixvim --> flake
  freenet --> flake
  pimonorepo --> pipkg --> overlay --> flake

  flake --> hoth
  flake --> ferrix
  flake --> nixvm
  flake --> jedha
  flake --> tests
  flake --> coruscant
  flake --> exegol
  flake --> standalone
  flake --> formatter
  flake --> pioutput

  class nixpkgs,darwin,hm,sops,wsl,nixvim,freenet,pimonorepo input
  class flake entry
  class overlay,pipkg local
  class hoth,ferrix,nixvm,jedha,tests,coruscant,exegol,standalone,formatter,pioutput output
```

The default overlay is injected into every package set constructed by
`flake.nix`. This is what makes `pkgs.pi-coding-agent` available to Home
Manager on every host. `pi-mono` supplies its source and version; the local
package expression supplies the reproducible Nix build and updater app.

## Host-to-user wiring

Solid arrows are direct host or profile imports. Dashed arrows show Home
Manager profiles attached by `flake.nix`.

```mermaid
flowchart LR
  classDef host fill:#e9f7e9,stroke:#3b7d3b,color:#111
  classDef profile fill:#f5e9ff,stroke:#7952a3,color:#111
  classDef module fill:#f4f4f4,stroke:#777,color:#111

  subgraph Linux[NixOS / Linux]
    hoth["hosts/hoth"]
    ferrix["hosts/ferrix"]
    nixvm["hosts/nixvm"]
    jedha["hosts/jedha · WSL"]
    hmstandalone["homeConfigurations.<br/>mpfammatter-linux"]
  end

  subgraph Mac[nix-darwin]
    tests["hosts/Tests-Virtual-Machine"]
    coruscant["hosts/Coruscant"]
    exegol["hosts/exegol"]
  end

  mp["users/mpfammatter.nix"]
  ui["users/mpfammatter-ui.nix"]
  jprofile["users/jedha.nix"]
  testprofile["users/test.nix"]
  inigo["users/inigo.nix<br/>system user module"]

  hoth -.->|HM: mpfammatter| mp
  hoth --> inigo
  ferrix -.->|HM: mpfammatter| ui
  nixvm -.->|HM: mpfammatter| mp
  jedha -.->|HM: mpfammatter| jprofile
  hmstandalone --> mp

  tests -.->|HM: test| testprofile
  coruscant -.->|HM: mpfammatter| ui
  exegol -.->|HM: mpfammatter| ui

  ui -->|extends| mp

  class hoth,ferrix,nixvm,jedha,hmstandalone,tests,coruscant,exegol host
  class mp,ui,jprofile,testprofile profile
  class inigo module
```

| Flake output | System | Host module | Home Manager profile |
| --- | --- | --- | --- |
| `homeConfigurations.mpfammatter-linux` | x86_64 Linux | — | `users/mpfammatter.nix` |
| `nixosConfigurations.hoth` | x86_64 Linux | `hosts/hoth` | `users/mpfammatter.nix` |
| `nixosConfigurations.ferrix` | x86_64 Linux | `hosts/ferrix` | `users/mpfammatter-ui.nix` plus `rustdesk` |
| `nixosConfigurations.nixvm` | x86_64 Linux | `hosts/nixvm` | `users/mpfammatter.nix` |
| `nixosConfigurations.jedha` | x86_64 Linux / WSL | `hosts/jedha` | `users/jedha.nix` |
| `darwinConfigurations.Tests-Virtual-Machine` | Apple Silicon macOS | `hosts/Tests-Virtual-Machine` | `users/test.nix` |
| `darwinConfigurations.Coruscant` | Apple Silicon macOS | `hosts/Coruscant` | `users/mpfammatter-ui.nix` |
| `darwinConfigurations.exegol` | Apple Silicon macOS | `hosts/exegol` | `users/mpfammatter-ui.nix` |

## Shared-module wiring

```mermaid
flowchart TB
  subgraph HostProfiles[Host profiles]
    linuxHosts["hoth · ferrix · nixvm"]
    jedha["jedha"]
    darwinHosts["Tests VM · Coruscant · exegol"]
  end

  subgraph HostModules[hosts/modules]
    fonts["fonts.nix"]
    nzsh["nixos-default-zsh.nix"]
    apple["appleDefaults.nix"]
    dzsh["default-zsh.nix"]
    brew["homebrew.nix"]
  end

  linuxHosts --> fonts
  linuxHosts --> nzsh
  jedha --> fonts
  jedha --> nzsh
  darwinHosts --> apple
  darwinHosts --> dzsh
  darwinHosts --> fonts
  darwinHosts --> brew

  subgraph HMProfiles[Home Manager profiles]
    mp["mpfammatter.nix"]
    ui["mpfammatter-ui.nix"]
    jp["jedha.nix"]
    tp["test.nix"]
  end

  subgraph UserModules[users/modules]
    base["mpfammatter-base.nix"]
    shell["zsh.nix → starship.nix"]
    editor["nixvim.nix"]
    terminal["wezterm.nix + colors"]
    pi["pi.nix"]
    espanso["espanso.nix"]
    ssh["ssh.nix"]
    keyboard["vimBindingKeyboardLayout.nix"]
    apps["uiApps.nix"]
    powertoys["powertoys.nix"]
  end

  mp --> base
  mp --> shell
  mp --> editor
  mp --> terminal
  mp --> pi
  mp --> espanso
  mp --> ssh
  mp --> keyboard

  ui --> mp
  ui --> apps

  jp --> base
  jp --> shell
  jp --> editor
  jp --> terminal
  jp --> pi
  jp --> keyboard
  jp --> powertoys

  tp --> shell
  tp --> editor
  tp --> terminal
  tp --> espanso
  tp --> keyboard
```

Hardware configuration remains local to `hoth`, `ferrix`, and `nixvm`.
`ferrix` additionally imports `zulip.nix`; `hoth` imports the `inigo` system
user module; `jedha` imports the `nixos-wsl` module. All integrated Home
Manager profiles receive the relevant upstream shared modules from
`flake.nix`, including `kickstart-nixvim`; sops-enabled profiles also receive
the sops-nix Home Manager module.

## Secrets and generated/exported configuration

```mermaid
flowchart LR
  secrets["secrets/<br/>SOPS-encrypted files"]
  sopsnix["sops-nix modules"]
  hosts["NixOS host services"]
  hmsecrets["Home Manager<br/>espanso.nix / ssh.nix"]
  hmprofiles["Home Manager<br/>profile activations"]
  windows["WSL exports<br/>WezTerm · Espanso · PowerToys"]
  winapps["Windows applications<br/>manual symlink"]

  secrets --> sopsnix
  sopsnix --> hosts
  sopsnix --> hmsecrets
  hmprofiles --> windows
  hmsecrets -.->|rendered Espanso secrets| windows
  windows -.->|UNC directory symlink| winapps
```

Encrypted files under `secrets/` are inputs only; decrypted values are
materialized by sops-nix at activation/runtime and must not be committed.
The Windows-facing exports are generated under `~/.local/share` by Home
Manager, then linked manually from Windows as documented in the main README.

## Apply paths

- NixOS host: `sudo nixos-rebuild switch --flake .#<host>`
- macOS host: `sudo darwin-rebuild switch --flake .#<host>`
- Standalone Linux profile: `home-manager switch --flake .#mpfammatter-linux`
- Cross-platform convenience path: the `apply` shell alias described in
  [`readme.md`](../readme.md)
