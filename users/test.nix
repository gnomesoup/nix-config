{ pkgs, ... }:
{
  imports = [
    ./modules/nixvim.nix
    ./modules/zsh.nix
    ./modules/wezterm.nix
  ];
  home = {
    username = "test";
    homeDirectory = "/Users/test";
    stateVersion = "23.11";
    packages = [
      pkgs.immich-cli
      pkgs.nixfmt
    ];
  };
  programs = {
    git = {
      enable = true;
      signing.format = "openpgp";
      userName = "Michael Pfammatter";
      userEmail = "pfammatter@gmail.com";
    };
    home-manager.enable = true;
    vscode = {
      enable = true;
    };
  };
}
