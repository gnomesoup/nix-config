{
  lib,
  nodejs,
  pi-coding-agent,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "pi-ask-local";
  version = "0.1.1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./extensions/pi-ask/index.ts
      ./extensions/pi-ask/index.test.ts
      ./skills/ask/SKILL.md
      ./LICENSE
      ./package.json
      ./README.md
    ];
  };

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
      extensions/pi-ask/index.ts extensions/pi-ask/index.test.ts
    "$piRoot/node_modules/.bin/tsx" --test extensions/pi-ask/index.test.ts

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r extensions skills LICENSE package.json README.md "$out/"

    runHook postInstall
  '';

  meta.description = "Interactive multi-question clarification extension for Pi";
}
