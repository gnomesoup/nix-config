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

    -- Use enumerate_ssh_hosts with explicit paths (default_ssh_domains has a bug with Include directive)
    local ssh_domains = {}
    local hosts = wezterm.enumerate_ssh_hosts(
      os.getenv("HOME") .. "/.ssh/config",
      os.getenv("HOME") .. "/.ssh/config.d/remote.conf"
    )
    for host, cfg in pairs(hosts) do
      table.insert(ssh_domains, {
        name = host,
        remote_address = cfg.hostname,
        username = cfg.user,
        assume_shell = 'Posix',
      })
    end
    config.ssh_domains = ssh_domains
    wezterm.log_info("SSH Domains generated:", #ssh_domains)

    config.keys = {
      {
        mods = "LEADER",
        key = "v",
        action = act.SplitHorizontal { domain = 'CurrentPaneDomain' }
      },
      {
        mods = "LEADER",
        key = "s",
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
