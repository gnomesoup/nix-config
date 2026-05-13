{
  pkgs,
  lib,
  config,
  ...
}:
{
  imports = [
    ./modules/mpfammatter-base.nix
    ./modules/nixvim.nix
    ./modules/pi.nix
    ./modules/powertoys.nix
    ./modules/vimBindingKeyboardLayout.nix
    ./modules/wezterm-colors.nix
    ./modules/wezterm.nix
    ./modules/zsh.nix
  ];

  programs.zsh.initContent = lib.mkAfter ''
    # NixOS' global /etc/zshrc initializes LS_COLORS with dircolors. On WSL,
    # Windows-mounted directories are often world-writable, so GNU ls uses the
    # other-writable/sticky directory colors. Replace the bright backgrounds with
    # a grey background to keep them readable.
    if [[ -n "$LS_COLORS" ]]; then
      LS_COLORS=":$LS_COLORS:"
      LS_COLORS="''${LS_COLORS//:ow=34;42:/:ow=34;47:}"
      LS_COLORS="''${LS_COLORS//:tw=30;42:/:tw=30;47:}"
      LS_COLORS="''${LS_COLORS//:st=37;44:/:st=37;47:}"
      LS_COLORS="''${LS_COLORS#:}"
      export LS_COLORS="''${LS_COLORS%:}"
    fi
  '';

  home.activation.exportWeztermForWindows = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    export_dir=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/wezterm-windows"}
    source_dir=${lib.escapeShellArg "${config.xdg.configHome}/wezterm"}

    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$export_dir/colors"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/wezterm.lua" "$export_dir/wezterm.lua"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/colors/SpaceVimDark.toml" "$export_dir/colors/SpaceVimDark.toml"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 644 "$export_dir/wezterm.lua" "$export_dir/colors/SpaceVimDark.toml"
  '';
}
