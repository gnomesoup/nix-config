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
    pkgs.hermes-desktop
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
    # `targets.darwin.linkApps` links the /Applications subpaths of
    # home.packages into "Applications/Home Manager Apps". Upstream
    # hermes-desktop ships no .app bundle, so this supplies one that
    # Launchpad and Spotlight can index.
    pkgs.hermes-desktop-app
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    gimpWithPlugins
    pkgs.scantailor-advanced
  ];
}
