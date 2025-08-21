{ pkgs, ... }: {
  home.packages = [
    # pkgs.plover.dev
    pkgs.zoom-us
    # pkgs.brave
  ];

  programs = {
    vscode.enable = true;
  };
}