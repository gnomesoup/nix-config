{ pkgs, vars, ... }:

{
  imports = [
    ../modules/appleDefaults.nix
    ../modules/fonts.nix
    ../modules/homebrew.nix
  ];

  environment.systemPackages = [
    pkgs.vim
    pkgs.git
    pkgs.python3
    pkgs.nixpkgs-fmt
    pkgs.raycast
    pkgs.utm
  ];

  # Necessary for using flakes on this system.
  nix.settings = {
    experimental-features = "nix-command flakes";
    substituters = [ "https://cache.nixos.org" ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };
  # nix.settings.extra-nix-path = "nixpkgs=flake:nixpkgs";

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
  system.primaryUser = "mpfammatter";

  # The platform the configuration will be used on.
  nixpkgs = {
    hostPlatform = "aarch64-darwin";
    config.allowUnfree = true;
  };

  programs = {
    direnv.enable = true;
    zsh.enable = true;
  };

  services.tailscale.enable = true;

  users.users.mpfammatter = {
    name = "mpfammatter";
    home = "/Users/mpfammatter";
  };
}
