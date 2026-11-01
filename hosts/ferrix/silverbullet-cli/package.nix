{
  lib,
  makeWrapper,
  python3,
  silverbullet,
  stdenvNoCC,
  callPackage,
  spaces ? {
    personal = "http://127.0.0.1:3000";
    ksp = "http://127.0.0.1:3000/ksp";
  },
}:
let
  upstream = callPackage ./upstream.nix { };
  connections = builtins.toFile "inigo-sb-connections.json" (builtins.toJSON spaces);
in
stdenvNoCC.mkDerivation {
  pname = "inigo-silverbullet-cli";
  inherit (upstream) version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./launcher.py
      ./test_launcher.py
      ./test_integration.py
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3 ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export SB_TEST_BINARY=${lib.getExe upstream}
    export SB_TEST_SERVER=${lib.getExe silverbullet}
    python3 -m unittest discover -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 launcher.py "$out/libexec/inigo-sb/launcher.py"
    mkdir -p "$out/bin"
    ln -s ${lib.getExe upstream} "$out/bin/sb"
    makeWrapper ${lib.getExe python3} "$out/bin/inigo-sb" \
      --add-flags "$out/libexec/inigo-sb/launcher.py ${lib.getExe upstream} ${connections}"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/sb" version
    "$out/bin/inigo-sb" personal fs edit --help > /dev/null
    "$out/bin/inigo-sb" ksp fs write --help > /dev/null
    runHook postInstallCheck
  '';

  passthru = { inherit upstream; };

  meta = {
    description = "Official SilverBullet CLI with private runtime authentication for Inigo";
    homepage = "https://docs.silverbullet.md/CLI";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "inigo-sb";
  };
}
