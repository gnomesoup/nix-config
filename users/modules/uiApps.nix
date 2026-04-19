{ pkgs, ... }:
{
  home.packages = [
    # pkgs.plover.dev
    pkgs.logseq
    pkgs.moonlight-qt
    pkgs.zoom-us
    # pkgs.brave
    # pkgs.ladybird
  ];
}
