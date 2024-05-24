{ pkgs, ... }: {
  imports = [ ./modules/zsh.nix ];
  home = {
    username = "test";
    homeDirectory = "/Users/test";
    stateVersion = "23.11";
    packages = [ pkgs.immich-cli pkgs.nixfmt-rfc-style ];
  };
  programs = {
    git = {
      enable = true;
      userName = "Michael Pfammatter";
      userEmail = "pfammatter@gmail.com";
    };
    home-manager.enable = true;
    vscode = { enable = true; };
  };
}
