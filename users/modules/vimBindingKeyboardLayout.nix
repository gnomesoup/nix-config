{ lib, config, ... }:
let
  layouts = import ./vimBindingLayouts.nix;
in
{
  options = {
    vimBindingKeyboardLayout = lib.mkOption {
      type = lib.types.enum [
        "qwerty"
        "colemak-dh"
      ];
      example = "qwerty";
      description = "Keyboard layout used for Vim-style keybindings across terminal tools.";
    };

    vimBindingKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "Semantic Vim-style bindings derived from `vimBindingKeyboardLayout`.";
    };
  };

  config = {
    vimBindingKeyboardLayout = lib.mkDefault "colemak-dh"; # managed by hms-kbl
    vimBindingKeys = layouts.${config.vimBindingKeyboardLayout};
  };
}
