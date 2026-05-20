{ pkgs, ... }:
{
  home.packages = [
    # pkgs.plover.dev
    pkgs.keymapp
    pkgs.logseq
    pkgs.super-productivity
    pkgs.zoom-us
    # pkgs.brave
    # pkgs.ladybird
  ];
}
