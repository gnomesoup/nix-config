{
  pkgs,
  lib,
  config,
  ...
}:
{
  imports = [
    ./modules/mpfammatter-base.nix
    ./modules/vimBindingKeyboardLayout.nix
    ./modules/nixvim.nix
    ./modules/wezterm.nix
    ./modules/wezterm-colors.nix
    ./modules/zsh.nix
  ];

  home.activation.exportWeztermForWindows = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    export_dir=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/wezterm-windows"}
    source_dir=${lib.escapeShellArg "${config.xdg.configHome}/wezterm"}

    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$export_dir/colors"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/wezterm.lua" "$export_dir/wezterm.lua"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/colors/SpaceVimDark.toml" "$export_dir/colors/SpaceVimDark.toml"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 644 "$export_dir/wezterm.lua" "$export_dir/colors/SpaceVimDark.toml"
  '';
}
