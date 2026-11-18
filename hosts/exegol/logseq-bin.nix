{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  makeWrapper,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "logseq-bin";
  version = "0.10.15";

  src = fetchurl {
    url = "https://github.com/logseq/logseq/releases/download/${finalAttrs.version}/Logseq-darwin-arm64-${finalAttrs.version}.zip";
    hash = "sha256-B4zs9CdCn44c55718v6GiClLbnbY7z+qffJAKdlfZ+4=";
  };

  nativeBuildInputs = [
    unzip
    makeWrapper
  ];
  sourceRoot = ".";
  dontBuild = true;
  # Leave the vendor bundle untouched for macOS code signing.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    test -x Logseq.app/Contents/MacOS/Logseq
    mkdir -p "$out/Applications"
    mv Logseq.app "$out/Applications/"
    makeWrapper "$out/Applications/Logseq.app/Contents/MacOS/Logseq" "$out/bin/logseq"

    runHook postInstall
  '';

  meta = {
    description = "Privacy-first knowledge management (upstream macOS binary)";
    homepage = "https://github.com/logseq/logseq";
    license = lib.licenses.agpl3Only;
    mainProgram = "logseq";
    platforms = [ "aarch64-darwin" ];
  };
})
