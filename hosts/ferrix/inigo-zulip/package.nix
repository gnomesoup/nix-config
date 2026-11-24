{
  lib,
  stdenvNoCC,
  hermesVenv,
}:

stdenvNoCC.mkDerivation {
  pname = "inigo-zulip-plugin";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./__init__.py
      ./adapter.py
      ./plugin.yaml
      ./test_adapter.py
    ];
  };

  nativeCheckInputs = [ hermesVenv ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    export HERMES_HOME="$TMPDIR/inigo-test-home"
    export HERMES_MANAGED=false
    mkdir -p "$HERMES_HOME"
    ${hermesVenv}/bin/python3 -m unittest discover -v

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp __init__.py adapter.py plugin.yaml "$out/"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    INIGO_ZULIP_PLUGIN_DIR="$out" ${hermesVenv}/bin/python3 test_adapter.py -v

    runHook postInstallCheck
  '';

  meta = {
    description = "Single-owner Zulip direct-message platform for Inigo";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
