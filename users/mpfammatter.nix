{
  pkgs,
  lib,
  config,
  ...
}:
{
  # users/modules/pi.nix declares piPackage as a module argument. The Nix module
  # system ignores defaults written in a module's signature (it forces a value
  # from config._module.args for every declared argument), so the importer must
  # supply it. mkDefault lets an importer override it, as users/jedha.nix does
  # with its Azure OpenAI wrapper.
  _module.args.piPackage = lib.mkDefault pkgs.pi-coding-agent;

  imports = [
    ./modules/espanso.nix
    ./modules/herdr.nix
    ./modules/mpfammatter-base.nix
    ./modules/nixvim.nix
    ./modules/pi.nix
    ./modules/ssh.nix
    ./modules/vimBindingKeyboardLayout.nix
    ./modules/wezterm-colors.nix
    ./modules/wezterm.nix
    ./modules/zsh.nix
  ];

  home.file = {
    ".pi/remote/config.json" = {
      force = true;
      text = builtins.toJSON {
        relay = "https://pi.tailbb897.ts.net";
      };
    };

    "inigo/.pi/remote-pi/config.json" = {
      force = true;
      text = builtins.toJSON {
        agent_name = "inigo";
        auto_start_relay = true;
      };
    };
  };

  home.activation.exportWeztermForWindows = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    export_dir=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/wezterm-windows"}
    source_dir=${lib.escapeShellArg "${config.xdg.configHome}/wezterm"}

    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$export_dir/colors"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/wezterm.lua" "$export_dir/wezterm.lua"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/colors/SpaceVimDark.toml" "$export_dir/colors/SpaceVimDark.toml"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 644 "$export_dir/wezterm.lua" "$export_dir/colors/SpaceVimDark.toml"
  '';
}
