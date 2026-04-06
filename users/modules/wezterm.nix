{ pkgs, config, ... }:
let
  keys = config.vimBindingKeys;
  weztermLua = ''
    local wezterm = require "wezterm"
    local act = wezterm.action
    local keys = {
      left = '${keys.left}',
      down = '${keys.down}',
      up = '${keys.up}',
      right = '${keys.right}',
      search_next = '${keys.searchNext}',
      search_prev = '${keys.searchPrev}',
      word_end = '${keys.wordEnd}',
      WORD_end = '${keys.WORDend}',
      find_forward = '${keys.findForward}',
      find_backward = '${keys.findBackward}',
      till_forward = '${keys.tillForward}',
      till_backward = '${keys.tillBackward}',
    }

    local function pick(list, index, fallback)
      if list ~= nil and list[index] ~= nil then
        return tostring(list[index])
      end
      return fallback
    end

    local function color_or(value, fallback)
      if value ~= nil then
        return tostring(value)
      end
      return fallback
    end

    local function status_style(window)
      local effective = window:effective_config()
      local palette = effective.resolved_palette
      local tab_bar = palette.tab_bar or {}
      local inactive_tab = tab_bar.inactive_tab or {}
      local active_tab = tab_bar.active_tab or {}

      local bar_bg = color_or(tab_bar.background, palette.background)
      local text = color_or(active_tab.fg_color, "#ffffff")

      return {
        bar_bg = bar_bg,
        text = text,
        normal = color_or(inactive_tab.bg_color, bar_bg),
        leader = pick(palette.ansi, 5, color_or(active_tab.bg_color, bar_bg)),
        copy = pick(palette.ansi, 6, color_or(active_tab.bg_color, bar_bg)),
        search = pick(palette.ansi, 4, color_or(active_tab.bg_color, bar_bg)),
        table = pick(palette.ansi, 3, color_or(active_tab.bg_color, bar_bg)),
      }
    end

    local function current_mode(window)
      if window:leader_is_active() then
        return "LEADER", "leader"
      end

      local key_table = window:active_key_table()
      if key_table == "resize_mode" then
        return "RESIZE", "table"
      end
      if key_table == "copy_mode" then
        return "COPY", "copy"
      end
      if key_table == "search_mode" then
        return "SEARCH", "search"
      end
      if key_table ~= nil then
        return string.upper(string.gsub(key_table, "_", " ")), "table"
      end

      return "NORMAL", "normal"
    end

    wezterm.on("update-status", function(window, _pane)
      local label, kind = current_mode(window)
      local colors = status_style(window)
      local accent = colors[kind] or colors.normal
      local text = colors.text
      local icon = "󰆍"

      if kind == "leader" then
        text = "#000000"
        icon = "🐡"
      end

      window:set_left_status(wezterm.format {
        { Background = { Color = accent } },
        { Foreground = { Color = text } },
        { Attribute = { Intensity = "Bold" } },
        { Text = " " .. icon .. " " .. label .. " " },
        "ResetAttributes",
      })
    end)

    local config = wezterm.config_builder and wezterm.config_builder() or {}

    config.color_scheme = "Monokai Pro (Gogh)"
    config.font = wezterm.font_with_fallback {
      "FiraCode Nerd Font",
    }
    config.font_size = 15.0
    config.hide_tab_bar_if_only_one_tab = false
    config.use_fancy_tab_bar = false
    config.tab_bar_at_bottom = true
    config.status_update_interval = 100
    -- config.window_decorations = "RESIZE"
    config.adjust_window_size_when_changing_font_size = false

    -- leader key config
    config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }

    local copy_mode = nil
    local search_mode = nil
    local resize_mode = nil
    if wezterm.gui then
      copy_mode = wezterm.gui.default_key_tables().copy_mode
      search_mode = wezterm.gui.default_key_tables().search_mode
      resize_mode = {
        {
          key = keys.left,
          mods = 'NONE',
          action = act.AdjustPaneSize { 'Left', 5 }
        },
        {
          key = keys.down,
          mods = 'NONE',
          action = act.AdjustPaneSize { 'Down', 5 }
        },
        {
          key = keys.up,
          mods = 'NONE',
          action = act.AdjustPaneSize { 'Up', 5 }
        },
        {
          key = keys.right,
          mods = 'NONE',
          action = act.AdjustPaneSize { 'Right', 5 }
        },
        {
          key = 'Escape',
          mods = 'NONE',
          action = act.PopKeyTable
        },
        {
          key = 'q',
          mods = 'NONE',
          action = act.PopKeyTable
        },
      }
      table.insert(copy_mode, {
        key = keys.left,
        mods = 'NONE',
        action = act.CopyMode 'MoveLeft'
      })
      table.insert(copy_mode, {
        key = keys.down,
        mods = 'NONE',
        action = act.CopyMode 'MoveDown'
      })
      table.insert(copy_mode, {
        key = keys.up,
        mods = 'NONE',
        action = act.CopyMode 'MoveUp'
      })
      table.insert(copy_mode, {
        key = keys.right,
        mods = 'NONE',
        action = act.CopyMode 'MoveRight'
      })
      table.insert(copy_mode, {
        key = keys.word_end,
        mods = 'NONE',
        action = act.CopyMode 'MoveForwardWordEnd'
      })
      table.insert(copy_mode, {
        key = keys.WORD_end,
        mods = 'NONE',
        action = act.CopyMode 'MoveForwardWordEnd'
      })
      table.insert(copy_mode, {
        key = keys.find_forward,
        mods = 'NONE',
        action = act.CopyMode { JumpForward = { prev_char = false } }
      })
      table.insert(copy_mode, {
        key = keys.find_backward,
        mods = 'NONE',
        action = act.CopyMode { JumpBackward = { prev_char = false } }
      })
      table.insert(copy_mode, {
        key = keys.till_forward,
        mods = 'NONE',
        action = act.CopyMode { JumpForward = { prev_char = true } }
      })
      table.insert(copy_mode, {
        key = keys.till_backward,
        mods = 'NONE',
        action = act.CopyMode { JumpBackward = { prev_char = true } }
      })

      table.insert(search_mode, {
        key = keys.search_next,
        mods = 'NONE',
        action = act.CopyMode 'NextMatch'
      })
      table.insert(search_mode, {
        key = keys.search_prev,
        mods = 'NONE',
        action = act.CopyMode 'PriorMatch'
      })
    end

    config.keys = {
      -- splitting
      {
        mods   = "LEADER",
        key    = "-",
        action = act.SplitVertical { domain = 'CurrentPaneDomain' }
      },
      {
        mods   = "LEADER",
        key    = "=",
        action = act.SplitHorizontal { domain = 'CurrentPaneDomain' }
      },
      -- navigation
      {
        key = keys.left,
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Left"
      },
      {
        key = keys.right,
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Right"
      },
      {
        key = keys.down,
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Down"
      },
      {
        key = keys.up,
        mods = 'LEADER',
        action = act.ActivatePaneDirection "Up"
      },
      {
        mods = 'LEADER|SHIFT',
        key = keys.left,
        action = act.TogglePaneZoomState
      },
      {
        mods = 'LEADER',
        key = 'r',
        action = act.ActivateKeyTable {
          name = 'resize_mode',
          one_shot = false,
          timeout_milliseconds = 1000,
        }
      },
      {
        mods = 'LEADER',
        key = 'w',
        action = act.PaneSelect {
          mode = 'Activate'
        }
      },
      {
        mods = 'SUPER',
        key = 'w',
        action = act.CloseCurrentPane { confirm = true }
      },
      -- activate copy mode
      {
        key = 'Enter',
        mods = 'LEADER',
        action = act.ActivateCopyMode
      }
    }

    config.key_tables = {
      copy_mode = copy_mode,
      search_mode = search_mode,
      resize_mode = resize_mode,
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
