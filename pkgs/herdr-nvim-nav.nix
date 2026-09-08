{
  fetchFromGitHub,
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "herdr-nvim-nav";
  version = "0.1.0-unstable-2026-08-02";

  src = fetchFromGitHub {
    owner = "aimdevlee";
    repo = "herdr-nvim-nav";
    rev = "ec047fd6d8d0269d54a34e9405af28d8aad4c8f0";
    hash = "sha256-2Sa10OaDgoy/Mw3lglrnmJn4RLUJv0dfU0MhXxXdnJI=";
  };

  strictDeps = true;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -o herdr-nvim-nav herdr-nvim-nav.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp herdr-plugin.toml herdr-nvim-nav LICENSE "$out/"
    cp -r lua "$out/lua"
    runHook postInstall
  '';

  meta = {
    description = "Seamless navigation across Herdr panes and Neovim splits";
    homepage = "https://github.com/aimdevlee/herdr-nvim-nav";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
