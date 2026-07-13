{ pkgs, ... }:
let
  gimpWithPlugins = pkgs.gimp-with-plugins.override {
    plugins = with pkgs.gimpPlugins; [
      bimp
      gmic
      resynthesizer
    ];
  };
in
{
  home.packages = [
    # pkgs.plover.dev
    pkgs.keymapp
    pkgs.logseq
    pkgs.super-productivity
    pkgs.zoom-us
    # pkgs.brave
    # pkgs.ladybird
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    gimpWithPlugins
    pkgs.scantailor-advanced
  ];
}
