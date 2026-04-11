{ pkgs, config, ... }:
let
  keys = config.vimBindingKeys;
  weztermLua = ''
    local wezterm = require "wezterm"
    local act = wezterm.action

    local config = wezterm.config_builder and wezterm.config_builder() or {}

    config.color_scheme = "Monokai Pro (Gogh)"
    config.font = wezterm.font_with_fallback {
      "FiraCode Nerd Font Mono",
    }
    config.font_size = 15.0
    config.hide_tab_bar_if_only_one_tab = false
    config.use_fancy_tab_bar = false
    config.tab_bar_at_bottom = true
    config.adjust_window_size_when_changing_font_size = false

    config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }

    config.keys = {
      {
        mods = "LEADER",
        key = "v",
        action = act.SplitHorizontal { domain = 'CurrentPaneDomain' }
      },
      {
        mods = "LEADER",
        key = "h",
        action = act.SplitVertical { domain = 'CurrentPaneDomain' }
      },
      {
        key = '${keys.left}',
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Left"
      },
      {
        key = '${keys.right}',
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Right"
      },
      {
        key = '${keys.down}',
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Down"
      },
      {
        key = '${keys.up}',
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Up"
      },
    }

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
