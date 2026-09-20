{ pkgs }:
let
  layouts = import ../../../users/modules/vimBindingLayouts.nix;
  generated = import ../../../users/modules/silverbullet-vim-layout-lib.nix {
    inherit (pkgs) lib;
  } { inherit layouts; };
  plugSource = pkgs.replaceVars ./vim-layout.ts {
    colemakLangmap = generated.langmap;
  };
in
assert pkgs.silverbullet.version == "2.10.0";
assert builtins.length generated.activeEntries == 16;
pkgs.buildNpmPackage {
  pname = "silverbullet-vim-layout-plug";
  inherit (pkgs.silverbullet.frontend)
    version
    src
    npmDeps
    patches
    ;

  postPatch = ''
    printf '%s\n' '{"version":"${pkgs.silverbullet.version}"}' > version.json
    mkdir -p plugs/nix-vim-layout
    cp ${./silverbullet-vim-layout.plug.yaml} plugs/nix-vim-layout/silverbullet-vim-layout.plug.yaml
    cp ${plugSource} plugs/nix-vim-layout/vim-layout.ts
    cp ${./vim-layout.test.ts} plugs/nix-vim-layout/vim-layout.test.ts
  '';

  buildPhase = ''
    runHook preBuild
    mkdir -p dist
    npx tsx bin/plug-compile.ts \
      --dist dist \
      plugs/nix-vim-layout/silverbullet-vim-layout.plug.yaml
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npx vitest run plugs/nix-vim-layout/vim-layout.test.ts
    npm run check
    grep -F 'editor.vimEx(command)' plugs/nix-vim-layout/vim-layout.ts
    ! grep -E 'Vim\.(map|noremap|unmap)|editor\.configureVimMode' plugs/nix-vim-layout/vim-layout.ts
    ! grep -E '^[[:space:]]+(key|mac):' plugs/nix-vim-layout/silverbullet-vim-layout.plug.yaml
    test -s dist/silverbullet-vim-layout.plug.js
    ! grep -F '@colemakLangmap@' dist/silverbullet-vim-layout.plug.js
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp dist/silverbullet-vim-layout.plug.js $out/
    runHook postInstall
  '';

  passthru = {
    inherit (generated) activeEntries langmap;
  };
}
