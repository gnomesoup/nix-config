{ pkgs, vars, ... }:

{
  imports = [
    ../modules/nixvim.nix
    ../modules/appleDefaults.nix
    ../modules/fonts.nix
    ../modules/kmonad.nix
  ];

  environment.systemPackages = [
    pkgs.vim
    pkgs.git
    pkgs.nixpkgs-fmt
    pkgs.raycast
    pkgs.warp-terminal
    pkgs.utm
  ];

  # Necessary for using flakes on this system.
  nix.settings.experimental-features = "nix-command flakes repl-flake";
  nix.settings.extra-nix-path = "nixpkgs=flake:nixpkgs";

  # The platform the configuration will be used on.
  nixpkgs = {
    hostPlatform = "aarch64-darwin";
    config.allowUnfree = true;
  };

  programs = {
    direnv.enable = true;
    zsh.enable = true;
  };

  services = {
    nix-daemon.enable = true;
    tailscale.enable = true;
  };

  users.users.mpfammatter = {
    name = "mpfammatter";
    home = "/Users/mpfammatter";
  };
}
