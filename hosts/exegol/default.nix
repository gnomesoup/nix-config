{ pkgs, vars, ... }:

{
  imports = [
    ../modules/nixvim.nix
    ../modules/appleDefaults.nix
    ../modules/fonts.nix
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
  nix.settings.experimental-features = "nix-command flakes";
  nix.settings.extra-nix-path = "nixpkgs=flake:nixpkgs";

  system.configurationVersion = self.rev or self.dirtyRev or null;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 5;

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
