{
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {

      format = ''
        [](color_orange)\
        $os\
        $username\
        [](bg:color_yellow fg:color_orange)\
        $directory\
        [](fg:color_yellow bg:color_aqua)\
        $git_branch\
        $git_status\
        [](fg:color_aqua bg:color_blue)\
        $c\
        $rust\
        $golang\
        $nodejs\
        $php\
        $java\
        $kotlin\
        $haskell\
        $python\
        [](fg:color_blue bg:color_bg3)\
        $docker_context\
        $conda\
        [](fg:color_bg3 bg:color_bg1)\
        $time\
        [ ](fg:color_bg1)\
        $line_break$character"""
      '';
      # pallette = "gruvbox_dark";
      pallette.gruvbox_dark = {
        color_fg0 = "#fbf1c7";
        color_bg1 = "#3c3836";
        color_bg3 = "#665c54";
        color_blue = "#458588";
        color_aqua = "#689d6a";
        color_green = "#98971a";
        color_orange = "#d65d0e";
        color_purple = "#b16286";
        color_red = "#cc241d";
        color_yellow = "#d79921";
      };
      os.disabled = false;
      os.style = "bg:color_orange fg:color_fg0";
      os.symbols = {
        Windows = "";
        macOS = "";
        Linux = "";
        Nix = "";
        Arch = "󰣇"
      };
      username = {
        show_always = true;
        style_user = "bg:color_orange fg:color_fg0";
        style_root = "bg:color_red fg:color_fg0";
        format = "[ $user ]($style)";
      };
    };
  };
}