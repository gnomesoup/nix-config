{ pkgs, config, ... }:

let
  spaceVimDarkToml = pkgs.writeText "SpaceVimDark.toml" ''
    [colors]
    foreground = "#b2b2b2"
    background = "#292b2e"
    cursor_bg = "#b2b2b2"
    cursor_fg = "#292b2e"
    cursor_border = "#b2b2b2"
    selection_bg = "#444155"
    selection_fg = "#b2b2b2"

    ansi = [
      "#1e1e1e",
      "#e0211d",
      "#67b11d",
      "#d1951d",
      "#4f97d7",
      "#bc6ec5",
      "#2aa1ae",
      "#b2b2b2",
    ]

    bright = [
      "#4e4e4e",
      "#ff5555",
      "#86dc2f",
      "#f0c674",
      "#6a9fd4",
      "#c56ec3",
      "#5ee7df",
      "#e0e0e0",
    ]

    indexed = []

    [colors.tab_bar]
    background = "#212026"
    active_tab = { bg_color = "#292b2e", fg_color = "#b2b2b2" }
    inactive_tab = { bg_color = "#212026", fg_color = "#757575" }

    [metadata]
    name = "SpaceVimDark"
    author = "Space-Vim theme"
  '';
in
{
  home.file = {
    "${config.xdg.configHome}/wezterm/colors/SpaceVimDark.toml" = {
      source = spaceVimDarkToml;
      recursive = false;
    };
  };
}
