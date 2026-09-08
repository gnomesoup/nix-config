{
  configFile,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "silverbullet-pi-extension";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./index.ts
      ./README.md
    ];
  };

  postPatch = ''
    substituteInPlace index.ts \
      --replace-fail '@configFile@' '${configFile}'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp index.ts README.md "$out/"

    runHook postInstall
  '';

  meta.description = "Direct SilverBullet HTTP API tools for Pi";
}
