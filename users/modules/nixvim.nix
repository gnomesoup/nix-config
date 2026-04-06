{ lib, config, ... }:
let
  keys = config.vimBindingKeys;

  mkNormalMap = key: action: {
    mode = "n";
    inherit key action;
  };
in
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
    plugins = {
      diffview.enable = true;
      neogit = {
        enable = true;
        settings = {
          integrations.diffview = true;
          mappings.status = {
            "${keys.right}" = "Toggle";
          };
        };
      };
      rainbow-delimiters.enable = true;
    };
    keymaps = [
      (mkNormalMap keys.left "h")
      (mkNormalMap keys.down "j")
      (mkNormalMap keys.up "k")
      (mkNormalMap keys.right "l")
      (mkNormalMap keys.searchNext "n")
      (mkNormalMap keys.searchPrev "N")
      (mkNormalMap keys.insert "i")
      (mkNormalMap keys.insertLineStart "I")
      (mkNormalMap keys.wordEnd "e")
      (mkNormalMap keys.WORDend "E")
      (mkNormalMap keys.setMark "m")
      (mkNormalMap keys.findForward "f")
      (mkNormalMap keys.findBackward "F")
      {
        mode = "n";
        key = "<leader>${keys.git}";
        action = "<cmd>Neogit<CR>";
        options = {
          desc = "Open Neogit";
          silent = true;
        };
      }
    ];
  };
}
