{
  programs.nixvim = {
    enable = true;
    opts = {
        number = true;
        relativenumber = true;
    };
    colorschemes.gruvbox.enable = true;
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