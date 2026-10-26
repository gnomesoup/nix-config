{
  lib,
  python3,
  silverbulletSkill ? ../../../agents/skills/silverbullet,
  stdenvNoCC,
  tzdata,
}:

stdenvNoCC.mkDerivation {
  pname = "inigo-silverbullet-plugin";
  version = "0.3.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./__init__.py
      ./client.py
      ./plugin.yaml
      ./schemas.py
      ./test_client.py
      ./test_journal.py
      ./test_shared_skill.py
    ];
  };

  nativeCheckInputs = [ python3 ];
  PYTHONTZPATH = "${tzdata}/share/zoneinfo";
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    mkdir -p skills
    cp -R ${silverbulletSkill} skills/silverbullet
    python3 -m unittest discover -v

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/skills/silverbullet"
    cp __init__.py client.py plugin.yaml schemas.py "$out/"
    cp -R ${silverbulletSkill}/. "$out/skills/silverbullet/"

    runHook postInstall
  '';

  meta = {
    description = "Direct, conflict-aware SilverBullet HTTP tools for Inigo";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
