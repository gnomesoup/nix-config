{
  lib,
  buildNpmPackage,
  fetchurl,
  importNpmLock,
  nix-update-script,
  versionCheckHook,
  src,
  version,
  writableTmpDirAsHomeHook,
  ripgrep,
  makeBinaryWrapper,
}:
let
  rootPackage = builtins.fromJSON (builtins.readFile "${src}/package.json");
  packageLock = builtins.fromJSON (builtins.readFile "${src}/package-lock.json");
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

  # importNpmLock only patches the root package files. The monorepo's web-ui
  # workspace currently declares xlsx as a direct URL dependency, so patch that
  # workspace package too even though this derivation only builds coding-agent.
  postPatch = lib.optionalString patchXlsx ''
    substituteInPlace packages/web-ui/package.json \
      --replace-fail '${xlsxPackage.resolved}' '${xlsxPackage.version}'
  '';

  npmWorkspace = "packages/coding-agent";

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

    npx tsgo -p packages/ai/tsconfig.build.json
    npx tsgo -p packages/tui/tsconfig.build.json
    npx tsgo -p packages/agent/tsconfig.build.json
    npm run build --workspace=packages/coding-agent

    runHook postBuild
  '';

  # npm workspace symlinks in the output point into packages/ which
  # doesn't exist there. Replace runtime deps with built content and
  # delete the rest.
  postInstall = ''
    local nm="$out/lib/node_modules/pi-monorepo/node_modules"

    # Replace workspace deps needed at runtime with real copies
    for ws in @mariozechner/pi-ai:packages/ai \
              @mariozechner/pi-agent-core:packages/agent \
              @mariozechner/pi-tui:packages/tui; do
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

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Coding agent CLI with read, bash, edit, write tools and session management";
    homepage = "https://shittycodingagent.ai/";
    downloadPage = "https://www.npmjs.com/package/@mariozechner/pi-coding-agent";
    changelog = "https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ munksgaard ];
    mainProgram = "pi";
  };
})
