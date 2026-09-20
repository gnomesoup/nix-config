{ pkgs }:
assert pkgs.silverbullet.version == "2.10.0";
pkgs.buildNpmPackage {
  pname = "silverbullet-journal-navigation-plug";
  inherit (pkgs.silverbullet.frontend)
    version
    src
    npmDeps
    patches
    ;

  postPatch = ''
    printf '%s\n' '{"version":"${pkgs.silverbullet.version}"}' > version.json
    mkdir -p plugs/nix-journal-navigation
    cp ${./silverbullet-journal-navigation.plug.yaml} plugs/nix-journal-navigation/silverbullet-journal-navigation.plug.yaml
    cp ${./journal-navigation.ts} plugs/nix-journal-navigation/journal-navigation.ts
    cp ${./journal-navigation.test.ts} plugs/nix-journal-navigation/journal-navigation.test.ts
  '';

  buildPhase = ''
    runHook preBuild
    mkdir -p dist
    npx tsx bin/plug-compile.ts \
      --dist dist \
      plugs/nix-journal-navigation/silverbullet-journal-navigation.plug.yaml
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npx vitest run plugs/nix-journal-navigation/journal-navigation.test.ts
    npm run check
    grep -F 'name: "Journal: Calendar"' plugs/nix-journal-navigation/silverbullet-journal-navigation.plug.yaml
    grep -F 'hooks:renderTopWidgets' ${./journal-navigation.md}
    grep -F 'dropdown = false' ${./journal-navigation.md}
    test -s dist/silverbullet-journal-navigation.plug.js
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp dist/silverbullet-journal-navigation.plug.js $out/
    runHook postInstall
  '';
}
