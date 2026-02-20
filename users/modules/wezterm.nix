{ pkgs, ... }:
let
  weztermLua = ''
    local wezterm = require "wezterm"
    local act = wezterm.action

    local config = wezterm.config_builder and wezterm.config_builder() or {}

    config.color_scheme = "Ayu Mirage"
    config.font = wezterm.font_with_fallback {
      "FiraCode Nerd Font",
    }
    config.font_size = 13.0
    config.hide_tab_bar_if_only_one_tab = true
    config.use_fancy_tab_bar = false
    config.window_decorations = "RESIZE"
    config.adjust_window_size_when_changing_font_size = false

    return config
  '';
in
{
  home.packages = [ pkgs.wezterm ];

  home.file.".config/wezterm/wezterm.lua" = {
    text = weztermLua;
    executable = false;
  };
}
