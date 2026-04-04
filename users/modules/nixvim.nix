{ lib, ... }:
{
  programs.nixvim = {
    # Personal Colemak-DH overrides layered on top of the kickstart base config.
    enable = true;
    clipboard.providers = {
      "wl-copy".enable = lib.mkForce false;
      xsel.enable = lib.mkForce false;
    };
    colorschemes = {
      tokyonight.enable = lib.mkForce false;
      monokai-pro.enable = true;
    };
    keymaps = [
      { key = "m"; action = "h"; }
      { key = "n"; action = "j"; }
      { key = "e"; action = "k"; }
      { key = "i"; action = "l"; }
      { key = "k"; action = "n"; }
      { key = "k"; action = "N"; }
      { key = "l"; action = "i"; }
      { key = "L"; action = "I"; }
      { key = "f"; action = "e"; }
      { key = "F"; action = "E"; }
      { key = "h"; action = "m"; }
      { key = "t"; action = "f"; }
      { key = "T"; action = "F"; }
    ];
  };
}