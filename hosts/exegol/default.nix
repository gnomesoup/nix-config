{ pkgs, vars, self, ... }:

{
  imports = [
    ../modules/nixvim.nix
    ../modules/appleDefaults.nix
    ../modules/fonts.nix
    ../modules/homebrew.nix
  ];

  environment.systemPackages = [
    pkgs.vim
    pkgs.git
    pkgs.nixpkgs-fmt
    pkgs.raycast
    pkgs.utm
    pkgs.vscodium
  ];

  # Necessary for using flakes on this system.
  nix.enable = false;
  nix.settings.experimental-features = "nix-command flakes";
  
  # nix.settings.extra-nix-path = "nixpkgs=flake:nixpkgs";

  system.configurationRevision = self.rev or self.dirtyRev or null;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 5;

  system.primaryUser = "mpfammatter";

  # The platform the configuration will be used on.
  nixpkgs = {
    hostPlatform = "aarch64-darwin";
    config.allowUnfree = true;
    config.allowBroken = true;
  };

  programs = {
    direnv.enable = true;
    zsh.enable = true;
  };

  services = {
    tailscale.enable = true;
  };

  users.users.mpfammatter = {
    name = "mpfammatter";
    home = "/Users/mpfammatter";
  };
}
