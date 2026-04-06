{ lib, config, ... }:
let
  layouts = {
    qwerty = {
      left = "h";
      down = "j";
      up = "k";
      right = "l";
      searchNext = "n";
      searchPrev = "N";
      insert = "i";
      insertLineStart = "I";
      wordEnd = "e";
      WORDend = "E";
      setMark = "m";
      findForward = "f";
      findBackward = "F";
      tillForward = "t";
      tillBackward = "T";
      git = "g";
    };
    "colemak-dh" = {
      left = "m";
      down = "n";
      up = "e";
      right = "i";
      searchNext = "k";
      searchPrev = "K";
      insert = "l";
      insertLineStart = "L";
      wordEnd = "f";
      WORDend = "F";
      setMark = "h";
      findForward = "t";
      findBackward = "T";
      tillForward = "r";
      tillBackward = "R";
      git = "g";
    };
  };
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
