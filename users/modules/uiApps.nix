{ pkgs, ... }:
let
  gimpWithPlugins = pkgs.gimp-with-plugins.override {
    plugins = with pkgs.gimpPlugins; [
      gmic
      resynthesizer
    ];
  };
in
{
  home.packages = [
    # pkgs.plover.dev
    pkgs.input-leap
    pkgs.keymapp
    pkgs.super-productivity
    pkgs.zoom-us
    # pkgs.brave
    # pkgs.ladybird
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.logseq
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    gimpWithPlugins
    pkgs.scantailor-advanced
  ];
}
