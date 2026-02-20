{ pkgs, ... }:
{
  imports = [
    ./modules/zsh.nix
    ./modules/wezterm.nix
  ];
  home = {
    username = "mpfammatter";
    # homeDirectory = "/Users/mpfammatter";
    stateVersion = "23.11";
    packages = [
      pkgs.immich-cli
      pkgs.nixfmt-rfc-style
    ];
  };

  programs = {
    git = {
      enable = true;
      settings.user.name = "Michael Pfammatter";
      settings.user.email = "pfammatter@gmail.com";
    };
    home-manager.enable = true;
  };
}
