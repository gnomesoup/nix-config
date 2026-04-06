{ pkgs, ... }:
{
  home = {
    username = "mpfammatter";
    sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };
    homeDirectory = if pkgs.stdenv.isDarwin then "/Users/mpfammatter" else "/home/mpfammatter";
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
      settings.user.name = "Michael Pfammatter";
      settings.user.email = "pfammatter@gmail.com";
    };
    home-manager.enable = true;
  };
}
