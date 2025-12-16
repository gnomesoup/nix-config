{ pkgs, ... }: {
  imports = [ ./modules/zsh.nix ];
  home = {
    username = "mpfammatter";
    # homeDirectory = "/Users/mpfammatter";
    stateVersion = "23.11";
    packages = [ pkgs.immich-cli pkgs.nixfmt-rfc-style ];
  };


  programs = {
    git = {
      enable = true;
      settings.userName = "Michael Pfammatter";
      settings.userEmail = "pfammatter@gmail.com";
    };
    home-manager.enable = true;
  };
}
