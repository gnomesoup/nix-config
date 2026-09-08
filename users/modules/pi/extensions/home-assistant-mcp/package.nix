{
  buildNpmPackage,
  configFile,
  lib,
}:
buildNpmPackage {
  pname = "home-assistant-mcp-pi-extension";
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./index.ts
      ./package-lock.json
      ./package.json
      ./README.md
    ];
  };

  npmDepsHash = "sha256-WMmlocP1/kB2Syj3gg2IySeNkGY1JX8iN4I7EfSaSoA=";
  dontNpmBuild = true;

  postPatch = ''
    substituteInPlace index.ts \
      --replace-fail '@configFile@' '${configFile}'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp index.ts package.json package-lock.json README.md "$out/"
    cp -r node_modules "$out/"

    runHook postInstall
  '';

  meta.description = "Ferrix Home Assistant MCP extension for Pi";
}
