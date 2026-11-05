{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  python3,
  silverbullet,
}:

stdenvNoCC.mkDerivation {
  pname = "silverbullet-edge";
  version = "2.12.0-242-gdbb715b2-2026-11-05T14-42-48Z";

  # Archive the moving upstream edge asset in our immutable GitHub release.
  src = fetchurl {
    url = "https://github.com/gnomesoup/nix-config/releases/download/silverbullet-edge-dbb715b298e5/silverbullet-server-linux-x86_64.zip";
    hash = "sha256-KAEloX3dLprOQZS6YMyBM7wG9BDd8+QZwCWVK1GQayU=";
  };

  nativeBuildInputs = [ unzip ];
  nativeInstallCheckInputs = [ python3 ];
  dontUnpack = true;
  dontBuild = true;
  # The upstream executable runs directly on NixOS; preserve its bytes.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    unzip "$src" -d upstream
    install -Dm755 upstream/silverbullet "$out/bin/silverbullet"
    install -Dm644 ${./LICENSE.md} "$out/share/doc/silverbullet/LICENSE.md"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    cmp upstream/silverbullet "$out/bin/silverbullet"
    "$out/bin/silverbullet" version | grep -F 'dbb715b2'
    export SB_TEST_SERVER="$out/bin/silverbullet"
    export SB_TEST_PREVIOUS_SERVER=${lib.getExe silverbullet}
    export SB_SYNC_SCRIPT=${../silverbullet-plug-sync.py}
    python3 ${./server-search_test.py}
    runHook postInstallCheck
  '';

  passthru.upstreamRevision = "dbb715b298e53f0daf6424de5ab3f627e1f77f0c";

  meta = {
    description = "Pinned upstream SilverBullet edge binary with server-side search";
    homepage = "https://silverbullet.md";
    license = lib.licenses.mit;
    mainProgram = "silverbullet";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
