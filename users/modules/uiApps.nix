{ pkgs, ... }:
let
  gimpWithPlugins = pkgs.gimp-with-plugins.override {
    plugins = with pkgs.gimpPlugins; [
      bimp
      gmic
      resynthesizer
    ];
  };
  superProductivity =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.super-productivity.overrideAttrs (old: {
        # macOS 26's iconutil rejects the regenerated source PNGs even though
        # the source's already-compiled ICNS is valid. Avoid the redundant
        # beforePack regeneration and use that checked-in icon instead.
        postPatch = (old.postPatch or "") + ''
          substituteInPlace electron-builder.yaml \
            --replace-fail "beforePack: ./tools/beforePack.js" ""
        '';
      })
    else
      pkgs.super-productivity;
in
{
  home.packages = [
    # pkgs.plover.dev
    pkgs.input-leap
    pkgs.keymapp
    pkgs.logseq
    superProductivity
    pkgs.zoom-us
    # pkgs.brave
    # pkgs.ladybird
  ]
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    gimpWithPlugins
    pkgs.scantailor-advanced
  ];
}
