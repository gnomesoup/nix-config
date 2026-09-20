{ pkgs }:
let
  source = pkgs.fetchFromGitHub {
    owner = "xunleii";
    repo = "silverbullet-icalendar";
    rev = "deb30ab6b323862329f2c8e61580b5104d94c40e";
    hash = "sha256-bO0lNSIqK+8J3uPRATOkHYqVyHEKOk6N+QL4lOfodVk=";
  };
  tsIcs = pkgs.fetchzip {
    url = "https://registry.npmjs.org/ts-ics/-/ts-ics-2.4.0.tgz";
    hash = "sha256-cep7cO+43jasLHA32AsPNyfhBtx8Dt8mQBHjDDl7HLs=";
  };
in
assert pkgs.silverbullet.version == "2.10.0";
pkgs.buildNpmPackage {
  pname = "silverbullet-icalendar-plug";
  version = "0.2.1-unstable-2025-10-18";
  inherit (pkgs.silverbullet.frontend)
    src
    npmDeps
    patches
    ;

  postPatch = ''
    printf '%s\n' '{"version":"${pkgs.silverbullet.version}"}' > version.json
    mkdir -p plugs/nix-icalendar
    cp ${source}/icalendar.plug.yaml plugs/nix-icalendar/icalendar.plug.yaml
    cp ${source}/icalendar.ts plugs/nix-icalendar/icalendar.ts
    substituteInPlace plugs/nix-icalendar/icalendar.ts \
      --replace-fail 'IcsDateObjects' 'IcsDateObject' \
      --replace-fail 'interface CalendarEvent extends DateToString<IcsEvent> {' 'type CalendarEvent = DateToString<IcsEvent> & {' \
      --replace-fail 'cacheDuration: number | undefined;' 'cacheDuration?: number;'
  '';

  buildPhase = ''
    runHook preBuild
    cp -R ${tsIcs} node_modules/ts-ics
    chmod -R u+w node_modules/ts-ics
    mkdir -p dist
    npx tsx bin/plug-compile.ts \
      --dist dist \
      plugs/nix-icalendar/icalendar.plug.yaml
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm run check
    test -s dist/icalendar.plug.js
    grep -F 'iCalendar: Force Sync' dist/icalendar.plug.js
    grep -F 'ical-event' dist/icalendar.plug.js
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp dist/icalendar.plug.js $out/
    runHook postInstall
  '';
}
