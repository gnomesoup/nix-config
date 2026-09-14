{
  lib,
  python3,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "inigo-silverbullet-plugin";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./__init__.py
      ./client.py
      ./plugin.yaml
      ./schemas.py
      ./skills/silverbullet/SKILL.md
      ./test_client.py
    ];
  };

  nativeCheckInputs = [ python3 ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    python3 -m unittest -v test_client.py

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/skills/silverbullet"
    cp __init__.py client.py plugin.yaml schemas.py "$out/"
    cp skills/silverbullet/SKILL.md "$out/skills/silverbullet/"

    runHook postInstall
  '';

  meta = {
    description = "Direct, conflict-aware SilverBullet HTTP tools for Inigo";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
