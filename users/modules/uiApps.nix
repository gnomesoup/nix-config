{ pkgs, ... }: {
  home.packages = [
    # pkgs.plover.dev
    pkgs.zoom-us

  ];

  programs = {
    vscode.enable = true;
  };
}