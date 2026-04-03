{ pkgs, ... }:
{
  home = {
    username = "mpfammatter";
    homeDirectory = if pkgs.stdenv.isDarwin then "/Users/mpfammatter" else "/home/mpfammatter";
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