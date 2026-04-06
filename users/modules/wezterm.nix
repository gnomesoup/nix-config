{ pkgs, config, ... }:
let
  keys = config.vimBindingKeys;
  weztermPresets = import ./wezterm-presets.nix;
  localWorkspacesJson = builtins.toJSON weztermPresets.localWorkspaces;
  remoteConfigPath = config.sops.secrets."mpfammatter/remote/config".path;
  weztermLua = ''
    local wezterm = require "wezterm"
    local act = wezterm.action
    local mux = wezterm.mux
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
    local local_workspaces = wezterm.json_parse([=[${localWorkspacesJson}]=])
    local remote_config_path = '${remoteConfigPath}'

    local function expand_home(path)
      if path == nil then
        return nil
      end

      return (path:gsub("^%$HOME", wezterm.home_dir))
    end

    local function read_file(path)
      local file = io.open(path, "r")
      if not file then
        return nil
      end

      local content = file:read("*a")
      file:close()
      return content
    end

    local function load_remote_config()
      local content = read_file(remote_config_path)
      if content == nil or content == "" then
        return { sshHosts = {} }
      end

      local ok, parsed = pcall(wezterm.json_parse, content)
      if not ok or parsed == nil then
        wezterm.log_error("Unable to parse remote WezTerm config at " .. remote_config_path)
        return { sshHosts = {} }
      end

      parsed.sshHosts = parsed.sshHosts or {}
      return parsed
    end

    local remote_config = load_remote_config()
    local ssh_hosts = remote_config.sshHosts

    local function host_by_alias(alias)
      for _, host in ipairs(ssh_hosts) do
        if host.alias == alias then
          return host
        end
      end

      return nil
    end

    local function configured_remote_hosts()
      local hosts = {}
      for _, host in ipairs(ssh_hosts) do
        table.insert(hosts, {
          name = host.alias,
          sshHost = host.alias,
          multiplexing = host.weztermMultiplexing or "WezTerm",
          assumeShell = host.assumeShell,
        })
      end

      table.sort(hosts, function(left, right)
        return left.name < right.name
      end)
      return hosts
    end

    local remote_hosts = configured_remote_hosts()

    local function ssh_domains_from_hosts()
      local domains = {}
      for _, host in ipairs(remote_hosts) do
        local domain = {
          name = "ssh:" .. host.name,
          remote_address = host.sshHost,
          multiplexing = host.multiplexing,
        }

        if host.multiplexing == "None" and host.assumeShell ~= nil then
          domain.assume_shell = host.assumeShell
        end

        table.insert(domains, domain)
      end

      return domains
    end

    local function domain_exists(name)
      for _, domain in ipairs(mux.all_domains()) do
        if domain:name() == name then
          return true
        end
      end

      return false
    end

    local function merged_workspace_choices()
      local choices = {}

      for _, workspace in ipairs(local_workspaces) do
        table.insert(choices, {
          id = "local:" .. workspace.name,
          label = "local  " .. workspace.name,
        })
      end

      for _, workspace in ipairs(remote_hosts) do
        table.insert(choices, {
          id = "remote:" .. workspace.name,
          label = "remote " .. workspace.name,
        })
      end

      return choices
    end

    local function find_workspace(list, name)
      for _, workspace in ipairs(list) do
        if workspace.name == name then
          return workspace
        end
      end

      return nil
    end

    local function switch_or_create_workspace(window, pane, workspace)
      window:perform_action(
        act.SwitchToWorkspace {
          name = workspace.name,
          spawn = {
            cwd = expand_home(workspace.path),
            domain = 'DefaultDomain',
            args = workspace.command,
          },
        },
        pane
      )
    end

    local function switch_or_create_remote_workspace(window, pane, workspace)
      local domain_name = "ssh:" .. workspace.sshHost
      if not domain_exists(domain_name) then
        window:toast_notification(
          "WezTerm",
          "Remote domain " .. domain_name .. " is not active yet. Fully quit and reopen WezTerm.",
          nil,
          5000
        )
        return
      end

      if workspace.multiplexing == "WezTerm" then
        window:toast_notification(
          "WezTerm",
          "Opening " .. workspace.sshHost .. " via remote WezTerm mux. If this hangs or opens locally, install WezTerm on the remote host or change that host to plain SSH fallback.",
          nil,
          4000
        )
      end

      window:perform_action(
        act.SwitchToWorkspace {
          name = workspace.name,
          spawn = {
            domain = { DomainName = domain_name },
          },
        },
        pane
      )
    end

    wezterm.on("workspace-launcher", function(window, pane)
      window:perform_action(
        act.InputSelector {
          title = "Projects / Sessions",
          description = "Select a local project or remote session",
          fuzzy = true,
          choices = merged_workspace_choices(),
          action = wezterm.action_callback(function(inner_window, inner_pane, id, _label)
            if id == nil then
              return
            end

            local kind, name = string.match(id, "^(%a+):(.+)$")
            if kind == "local" then
              local workspace = find_workspace(local_workspaces, name)
              if workspace ~= nil then
                switch_or_create_workspace(inner_window, inner_pane, workspace)
              else
                inner_window:toast_notification("WezTerm", "Local workspace not found: " .. name, nil, 4000)
              end
            elseif kind == "remote" then
              local workspace = find_workspace(remote_hosts, name)
              if workspace ~= nil then
                switch_or_create_remote_workspace(inner_window, inner_pane, workspace)
              else
                inner_window:toast_notification("WezTerm", "Remote SSH alias not found: " .. name, nil, 4000)
              end
            end
          end),
        },
        pane
      )
    end)

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

      window:set_right_status(wezterm.format {
        { Attribute = { Intensity = "Bold" } },
        { Text = " 󱂬 " .. window:active_workspace() .. " " },
      })
    end)

    local config = wezterm.config_builder and wezterm.config_builder() or {}
    config.ssh_domains = ssh_domains_from_hosts()

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
      {
        mods = 'LEADER',
        key = 'p',
        action = act.EmitEvent 'workspace-launcher'
      },
      {
        mods = 'LEADER|SHIFT',
        key = 'P',
        action = act.PromptInputLine {
          description = 'Enter name for new workspace',
          action = wezterm.action_callback(function(window, pane, line)
            if line and line ~= "" then
              window:perform_action(
                act.SwitchToWorkspace {
                  name = line,
                },
                pane
              )
            end
          end),
        }
      },
      {
        mods = 'LEADER',
        key = '1',
        action = act.ActivateTab(0)
      },
      {
        mods = 'LEADER',
        key = '2',
        action = act.ActivateTab(1)
      },
      {
        mods = 'LEADER',
        key = '3',
        action = act.ActivateTab(2)
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
