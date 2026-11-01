{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

stdenvNoCC.mkDerivation rec {
  pname = "silverbullet-cli-upstream";
  version = "2.12.1";

  src = fetchurl {
    url = "https://github.com/silverbulletmd/silverbullet/releases/download/${version}/sb-linux-x86_64.zip";
    hash = "sha256-oEsyl6AJ1bLf2YUKS32RVhg2j5WXKK3LEjsElJwLBTM=";
  };

  nativeBuildInputs = [ unzip ];
  dontUnpack = true;
  dontBuild = true;
  # Preserve the official, directly executable upstream binary unchanged.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    unzip "$src" -d upstream
    install -Dm755 upstream/sb "$out/bin/sb"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    export HOME="$TMPDIR/sb-home"
    export NO_COLOR=1
    mkdir -p "$HOME"
    "$out/bin/sb" version | grep -F '${version}'
    for command in read write edit stat rm; do
      "$out/bin/sb" fs "$command" --help > "$TMPDIR/sb-$command-help"
      grep -F "sb fs $command" "$TMPDIR/sb-$command-help"
    done

    runHook postInstallCheck
  '';

  meta = {
    description = "Official SilverBullet CLI with remote filesystem commands";
    homepage = "https://silverbullet.md";
    license = lib.licenses.mit;
    mainProgram = "sb";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
