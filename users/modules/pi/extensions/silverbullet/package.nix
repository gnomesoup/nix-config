{
  configFile,
  lib,
  nodejs,
  pi-coding-agent,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "silverbullet-pi-extension";
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./index.ts
      ./package.json
      ./README.md
      ./test.ts
    ];
  };

  postPatch = ''
    substituteInPlace index.ts \
      --replace-fail '@configFile@' '${configFile}'
  '';

  nativeCheckInputs = [ nodejs ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    piRoot=${pi-coding-agent}/lib/node_modules/pi-monorepo
    mkdir -p node_modules/@earendil-works
    for package in "$piRoot"/node_modules/@earendil-works/*; do
      ln -s "$package" "node_modules/@earendil-works/$(basename "$package")"
    done
    ln -s "$piRoot" node_modules/@earendil-works/pi-coding-agent
    ln -s "$piRoot/node_modules/@types" node_modules/@types
    ln -s "$piRoot/node_modules/typebox" node_modules/typebox
    "$piRoot/node_modules/.bin/tsc" \
      --allowImportingTsExtensions \
      --module NodeNext \
      --moduleResolution NodeNext \
      --noEmit \
      --skipLibCheck \
      --target ES2023 \
      --types node \
      index.ts test.ts
    "$piRoot/node_modules/.bin/tsx" --test test.ts

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp index.ts package.json README.md "$out/"

    runHook postInstall
  '';

  meta.description = "Direct SilverBullet HTTP API tools for Pi";
}
