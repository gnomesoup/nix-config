{ pkgs, ... }: {
  home.packages = [
    # pkgs.plover.dev
    pkgs.zoom-us
    # pkgs.brave
    pkgs.ladybird
  ];

  programs = {
    vscode.enable = true;
  };
}