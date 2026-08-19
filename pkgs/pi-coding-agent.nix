{
  lib,
  buildNpmPackage,
  fetchurl,
  importNpmLock,
  python3,
  versionCheckHook,
  src,
  version,
  writableTmpDirAsHomeHook,
  ripgrep,
  makeBinaryWrapper,
  writeShellApplication,
}:
let
  rootPackage = builtins.fromJSON (builtins.readFile "${src}/package.json");
  sourcePackageLock = builtins.fromJSON (builtins.readFile "${src}/package-lock.json");
  vendoredPackageLock = builtins.fromJSON (builtins.readFile ./pi-coding-agent-package-lock.json);
  # The upstream lockfile for pi-coding-agent 0.74.0 omits registry
  # resolved/integrity fields, which nixpkgs' importNpmLock requires.
  # Regenerate with:
  #   rm package-lock.json && npm install --package-lock-only --ignore-scripts --no-audit --no-fund
  packageLock = if version == "0.74.0" then vendoredPackageLock else sourcePackageLock;
  xlsxPackage = packageLock.packages."node_modules/xlsx" or null;
  webUiPackage = packageLock.packages."packages/web-ui" or null;
  patchXlsx =
    xlsxPackage != null
    && webUiPackage != null
    && (webUiPackage.dependencies or { }) ? xlsx
    && webUiPackage.dependencies.xlsx == xlsxPackage.resolved;
  xlsxTarball =
    if patchXlsx then
      fetchurl {
        url = xlsxPackage.resolved;
        hash = xlsxPackage.integrity;
      }
    else
      null;
  # pi-ai >= 0.82 generates provider model catalogs as JSON files that are
  # present in the published npm package but ignored in the GitHub source
  # archive. Fetch the matching npm package and hydrate those files locally so
  # the TypeScript build remains offline/reproducible under Nix. After updating
  # the pi-mono input, refresh this map with:
  #   nix run .#update-pi-coding-agent
  aiModelDataTarballs = {
    "0.82.1" = fetchurl {
      url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-0.82.1.tgz";
      hash = "sha512-3WFYRhEp3lQB3444EhPMBcM7zSaEUE3eJgHOR7s4081NLqbw/FsWilIKWXSua0Gv3sRr7m9xMidR3pPDE7jI/A==";
    };
    "0.84.1" = fetchurl {
      url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-0.84.1.tgz";
      hash = "sha256-araJGJ58s95c2xJjEqPmDorDX+XuXxtj0A9xHIpDDHM=";
    };
    "0.84.2" = fetchurl {
      url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-0.84.2.tgz";
      hash = "sha512-6MzsrYIYNVlE7SfpbL2yYb67Qo58p/7Q+xWG1RZvoX1P80aRCHSod2/13aFpxkow1lPO2LEh3c495J0Gwmyjig==";
    };
  };
  aiModelDataTarball = aiModelDataTarballs.${version} or null;
  updateScript = writeShellApplication {
    name = "update-pi-coding-agent";
    runtimeInputs = [ python3 ];
    text = ''
      exec python3 ${./update-pi-coding-agent.py} --version ${lib.escapeShellArg version} "$@"
    '';
  };
  patchedPackageLock =
    if patchXlsx then
      packageLock
      // {
        packages = packageLock.packages // {
          "packages/web-ui" = webUiPackage // {
            dependencies = webUiPackage.dependencies // {
              xlsx = xlsxPackage.version;
            };
          };
        };
      }
    else
      packageLock;
in
buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  inherit src version;

  # Keep the model and thinking-level indicator visible in narrow terminals.
  patches = [ ./pi-footer-wrap.patch ];

  npmDeps = importNpmLock {
    npmRoot = finalAttrs.src;
    package = rootPackage;
    packageLock = patchedPackageLock;
    pname = rootPackage.name or "pi-monorepo";
    version = rootPackage.version or "0.0.0";
    packageSourceOverrides = lib.optionalAttrs patchXlsx {
      "node_modules/xlsx" = xlsxTarball;
    };
  };
  npmConfigHook = importNpmLock.npmConfigHook;

  # Hydrate generated pi-ai model data when the GitHub archive omits it.
  # importNpmLock only patches the root package files; patch web-ui separately
  # when it declares xlsx as a direct URL dependency.
  postPatch =
    lib.optionalString (aiModelDataTarball != null) ''
      model_data_tmp=$(mktemp -d)
      tar -xzf ${aiModelDataTarball} -C "$model_data_tmp"
      mkdir -p packages/ai/src/providers/data
      cp -R "$model_data_tmp/package/dist/providers/data/." packages/ai/src/providers/data/
    ''
    + lib.optionalString patchXlsx ''
      substituteInPlace packages/web-ui/package.json \
        --replace-fail '${xlsxPackage.resolved}' '${xlsxPackage.version}'
    '';

  npmWorkspace = "packages/coding-agent";
  dontNpmPrune = true;

  # Skip native module rebuild for unneeded workspaces (e.g. canvas from web-ui)
  npmRebuildFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    makeBinaryWrapper
  ];

  # Build workspace dependencies in order, then the coding-agent.
  # We invoke tsgo directly for workspace deps to skip pi-ai's
  # generate-models script which requires network access
  # (models.generated.ts is committed to the repo).
  buildPhase = ''
    runHook preBuild

    npx tsgo -p packages/telemetry/tsconfig.build.json
    npx tsgo -p packages/ai/tsconfig.build.json
    rm -rf packages/ai/dist/providers/data
    cp -R packages/ai/src/providers/data packages/ai/dist/providers/data
    npx tsgo -p packages/tui/tsconfig.build.json
    npx tsgo -p packages/agent/tsconfig.build.json
    npx tsgo -p packages/protocol/tsconfig.build.json
    npx tsgo -p packages/client/tsconfig.build.json
    npm run build --workspace=packages/coding-agent

    runHook postBuild
  '';

  # npm workspace symlinks in the output point into packages/ which
  # doesn't exist there. Replace runtime deps with built content and
  # delete the rest.
  postInstall = ''
    local nm="$out/lib/node_modules/pi-monorepo/node_modules"

    # Replace workspace deps needed at runtime with real copies
    for ws in @earendil-works/pi-ai:packages/ai \
              @earendil-works/pi-telemetry:packages/telemetry \
              @earendil-works/pi-agent-core:packages/agent \
              @earendil-works/pi-client:packages/client \
              @earendil-works/pi-protocol:packages/protocol \
              @earendil-works/pi-tui:packages/tui; do
      IFS=: read -r pkg src <<< "$ws"
      rm "$nm/$pkg"
      cp -r "$src" "$nm/$pkg"
    done

    # Delete remaining workspace symlinks
    find "$nm" -type l -lname '*/packages/*' -delete

    # Clean up now-dangling .bin symlinks
    find "$nm/.bin" -xtype l -delete
  '';
  postFixup = "wrapProgram $out/bin/pi --prefix PATH : ${lib.makeBinPath [ ripgrep ]}";

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgram = "${placeholder "out"}/bin/pi";
  versionCheckProgramArg = "--version";

  passthru = {
    updateScript = lib.getExe updateScript;
    updateScriptPackage = updateScript;
  };

  meta = {
    description = "Coding agent CLI with read, bash, edit, write tools and session management";
    homepage = "https://shittycodingagent.ai/";
    downloadPage = "https://www.npmjs.com/package/@earendil-works/pi-coding-agent";
    changelog = "https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ munksgaard ];
    mainProgram = "pi";
  };
})
