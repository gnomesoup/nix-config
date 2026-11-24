{
  lib,
  stdenvNoCC,
  python3,
  docker,
  makeWrapper,
}:

stdenvNoCC.mkDerivation {
  pname = "inigo-zulip-provision";
  version = "1";

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      type == "directory"
      || builtins.elem (baseNameOf path) [
        "provision.py"
        "policy.py"
        "container.py"
        "test_provision.py"
      ];
  };

  nativeBuildInputs = [ makeWrapper ];

  postPatch = ''
    substituteInPlace provision.py --replace-fail '@docker@' '${docker}/bin/docker'
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export PYTHONDONTWRITEBYTECODE=1
    ${python3}/bin/python3 -m unittest -v test_provision
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    destination="$out/libexec/inigo-zulip-provision"
    mkdir -p "$destination" "$out/bin"
    install -m444 provision.py policy.py container.py test_provision.py "$destination/"
    makeWrapper ${python3}/bin/python3 "$out/bin/inigo-zulip-provision" \
      --add-flags "-B -E $destination/provision.py"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    cd "$out/libexec/inigo-zulip-provision"
    INIGO_PROVISION_CLI="$out/bin/inigo-zulip-provision" ${python3}/bin/python3 -m unittest -v test_provision
    runHook postInstallCheck
  '';

  meta = {
    description = "Root-only idempotent provisioning for Ferrix's Inigo Zulip bot";
    mainProgram = "inigo-zulip-provision";
    platforms = lib.platforms.linux;
  };
}
