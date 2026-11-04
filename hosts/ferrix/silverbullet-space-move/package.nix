{ pkgs }:
pkgs.buildNpmPackage {
  pname = "silverbullet-space-move-plug";
  inherit (pkgs.silverbullet.frontend)
    version
    src
    npmDeps
    patches
    ;

  postPatch = ''
    printf '%s\n' '{"version":"${pkgs.silverbullet.version}"}' > version.json
    mkdir -p plugs/nix-space-move
    cp -r ${./.}/. plugs/nix-space-move/
    chmod -R u+w plugs/nix-space-move
  '';

  buildPhase = ''
    runHook preBuild
    mkdir -p dist
    npx tsx bin/plug-compile.ts --dist dist \
      plugs/nix-space-move/silverbullet-space-move.plug.yaml
    runHook postBuild
  '';

  doCheck = true;
  # The sandbox has no host fonts; Chromium otherwise crashes while rendering.
  FONTCONFIG_FILE = pkgs.makeFontsConf {
    fontDirectories = [ pkgs.dejavu_fonts ];
    impureFontDirectories = [ ];
    includes = [ ];
  };
  nativeCheckInputs = [
    pkgs.chromium
    pkgs.silverbullet
  ];
  checkPhase = ''
    runHook preCheck
    node --experimental-strip-types --test \
      plugs/nix-space-move/core.test.ts \
      plugs/nix-space-move/engine.test.ts \
      plugs/nix-space-move/transport.test.ts
    npx vitest run plugs/nix-space-move/parser.test.ts \
      plugs/nix-space-move/space-move.test.ts \
      plugs/nix-space-move/controller.test.ts
    npm run check
    export HOME="$TMPDIR/space-move-home"
    mkdir -p "$HOME"
    SB_TEST_SERVER=${pkgs.silverbullet}/bin/silverbullet \
      SB_TEST_CHROMIUM=${pkgs.chromium}/bin/chromium \
      npx tsx plugs/nix-space-move/browser.test.ts
    test -s dist/silverbullet-space-move.plug.js
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp dist/silverbullet-space-move.plug.js $out/
    runHook postInstall
  '';
}
