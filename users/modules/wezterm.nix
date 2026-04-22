{ pkgs, config, ... }:
let
  keys = config.vimBindingKeys;
  weztermLua = ''
    local wezterm = require "wezterm"
    local act = wezterm.action
    local mux = wezterm.mux
    local is_windows = wezterm.target_triple:find("windows") ~= nil

    local config = wezterm.config_builder and wezterm.config_builder() or {}

    local function trim(text)
      if not text then
        return nil
      end

      return text:gsub("^%s+", ""):gsub("%s+$", "")
    end

    local function notify(window, message)
      window:toast_notification("WezTerm Projects", message, nil, 4000)
    end

    local function is_local_file_url(url)
      return url
        and url.scheme == "file"
        and (url.host == nil or url.host == "" or url.host == "localhost" or url.host == wezterm.hostname())
    end

    local function pane_path(pane)
      local cwd = pane:get_current_working_dir()
      if not cwd then
        return nil, "Current pane has no working directory"
      end

      if type(cwd) == "string" then
        cwd = wezterm.url.parse(cwd)
      end

      if not is_local_file_url(cwd) then
        return nil, "Project launcher only supports local panes"
      end

      return cwd.file_path, nil
    end

    local function git_root_for_path(path)
      local success, stdout = wezterm.run_child_process {
        "git",
        "-C",
        path,
        "rev-parse",
        "--show-toplevel",
      }
      if not success then
        return nil
      end

      return trim(stdout)
    end

    local function project_info_for_pane(pane)
      local path, path_error = pane_path(pane)
      if not path then
        return nil, path_error
      end

      local git_root = git_root_for_path(path)
      if not git_root then
        return nil, "Current pane is not inside a git project"
      end

      local project_name = git_root:match("([^/]+)$")
      if not project_name or project_name == "" then
        return nil, "Could not determine project name"
      end

      return {
        name = project_name,
        root = git_root,
      }, nil
    end

    local function workspace_exists(name)
      for _, workspace_name in ipairs(mux.get_workspace_names()) do
        if workspace_name == name then
          return true
        end
      end

      return false
    end

    local function workspace_roots(name)
      local roots = {}

      for _, mux_window in ipairs(mux.all_windows()) do
        if mux_window:get_workspace() == name then
          for _, tab in ipairs(mux_window:tabs()) do
            for _, pane in ipairs(tab:panes()) do
              local path = pane_path(pane)
              if path then
                local git_root = git_root_for_path(path)
                if git_root then
                  roots[git_root] = true
                end
              end
            end
          end
        end
      end

      return roots
    end

    local function single_workspace_root(name)
      local roots = workspace_roots(name)
      local count = 0
      local root = nil

      for candidate_root, _ in pairs(roots) do
        count = count + 1
        root = candidate_root
      end

      if count == 1 then
        return root, nil
      end

      if count > 1 then
        return nil, "ambiguous"
      end

      return nil, nil
    end

    local function find_workspace_window(name)
      for _, mux_window in ipairs(mux.all_windows()) do
        if mux_window:get_workspace() == name then
          return mux_window
        end
      end

      return nil
    end

    local function build_project_workspace(window, pane)
      local project, project_error = project_info_for_pane(pane)
      if not project then
        notify(window, project_error)
        return
      end

      local existing_workspace = workspace_exists(project.name)
      local existing_root, root_error = single_workspace_root(project.name)

      if existing_root == project.root then
        window:perform_action(act.SwitchToWorkspace { name = project.name }, pane)
        return
      end

      if existing_workspace then
        if root_error == "ambiguous" then
          notify(window, "Workspace '" .. project.name .. "' already exists with multiple roots")
          return
        end

        if existing_root then
          notify(
            window,
            "Workspace '" .. project.name .. "' already exists for " .. existing_root
          )
          return
        end

        notify(window, "Workspace '" .. project.name .. "' already exists and cannot be verified")
        return
      end

      window:perform_action(
        act.SwitchToWorkspace {
          name = project.name,
          spawn = {
            cwd = project.root,
            args = { "zsh", "-c", "nvim; exec zsh" },
          },
        },
        pane
      )

      for _ = 1, 20 do
        wezterm.sleep_ms(25)
        local mux_window = find_workspace_window(project.name)
        if mux_window then
          local tab = mux_window:active_tab()
          if tab then
            local editor_pane = tab:active_pane()
            if editor_pane and #tab:panes() == 1 then
              tab:set_title(project.name)
              editor_pane:split {
                direction = "Bottom",
                top_level = true,
                size = 12,
                cwd = project.root,
              }
              editor_pane:split {
                direction = "Right",
                size = 0.25,
                cwd = project.root,
                args = { "zsh", "-c", "opencode -c; exec zsh" },
              }
              editor_pane:activate()
              return
            end
          end
        end
      end

      notify(window, "Created workspace '" .. project.name .. "' but could not finish the layout")
    end

    wezterm.on("update-right-status", function(window, pane)
      local workspace_name = window:active_workspace()
      local domain_name = pane:get_domain_name()

      local overrides = window:get_config_overrides() or {}
      local palette = overrides.resolved_palette

      local grey_bg = palette and palette.bg3 or '#444444'
      local purple_fg = palette and palette.purple or '#a389d8'
      local orange_bg = palette and palette.orange or '#ff9900'
      local black_fg = palette and palette.fg0 or '#000000'

      local ws = wezterm.format({
        { Background = { Color = grey_bg } },
        { Foreground = { Color = purple_fg } },
        { Text = " " .. workspace_name .. " " },
      })

      local dom = wezterm.format({
        { Background = { Color = orange_bg } },
        { Foreground = { Color = black_fg } },
        { Text = " " .. domain_name .. " " },
      })

      window:set_right_status(ws .. dom)
    end)

    wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
      local palette = config.resolved_palette
      local tab_index = tab.tab_index + 1

      local green_fg = palette and palette.green or '#50fa7b'
      local purple_bg = palette and palette.purple or '#bd93f9'
      local black_fg = palette and palette.fg0 or '#000000'
      local grey_fg = palette and palette.fg1 or '#abb2bf'
      local grey_bg = palette and palette.bg1 or '#333'
      local black_bg = palette and palette.bg0 or '#000000'
      local terminal_bg = palette and palette.bg0 or '#000000'

      local title = tab.active_pane.title

      if tab.is_active then
        return {
          { Background = { Color = green_fg } },
          { Foreground = { Color = black_fg } },
          { Text = " " .. tab_index .. " " },
          { Background = { Color = terminal_bg } },
          { Foreground = { Color = grey_fg } },
          { Text = " " .. title .. " " },
        }
      else
        return {
          { Background = { Color = purple_bg } },
          { Foreground = { Color = black_fg } },
          { Text = " " .. tab_index .. " " },
          { Background = { Color = grey_bg } },
          { Foreground = { Color = grey_fg } },
          { Text = " " .. title .. " " },
        }
      end
    end)

    config.color_scheme = "SpaceVimDark"
    config.colors = {
      cursor_bg = "#d1951d",
      cursor_border = "#d1951d",
      cursor_fg = "#292b2e",
    }
    config.font = wezterm.font_with_fallback {
      "SauceCodePro Nerd Font Mono",
      "FiraCode Nerd Font Mono",
    }
    config.font_size = 16.0
    config.hide_tab_bar_if_only_one_tab = false
    config.use_fancy_tab_bar = false
    config.tab_bar_at_bottom = true
    config.tab_bar_style = {
      new_tab = wezterm.format({
        { Background = { Color = '#444444' } },
        { Foreground = { Color = '#50fa7b' } },
        { Text = " + " },
      }),
    }
    config.adjust_window_size_when_changing_font_size = false

    if is_windows then
      config.default_domain = "WSL:NixOS"
    end

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

    config.key_tables = {
      resize_pane = {
        {
          key = '${keys.left}',
          action = act.AdjustPaneSize { "Left", 3 }
        },
        {
          key = '${keys.right}',
          action = act.AdjustPaneSize { "Right", 3 }
        },
        {
          key = '${keys.down}',
          action = act.AdjustPaneSize { "Down", 3 }
        },
        {
          key = '${keys.up}',
          action = act.AdjustPaneSize { "Up", 3 }
        },
        {
          key = 'Escape',
          action = act.PopKeyTable
        },
        {
          key = 'Enter',
          action = act.PopKeyTable
        },
      },
    }

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
        key = 'r',
        mods = 'LEADER',
        action = act.ActivateKeyTable {
          name = 'resize_pane',
          one_shot = false,
          timeout_milliseconds = 2500,
          until_unknown = true,
        }
      },
      {
        key = '${keys.left}',
        mods = 'CTRL',
        action = act.ActivatePaneDirection "Left"
      },
      {
        key = '${keys.right}',
        mods = 'CTRL',
        action = act.ActivatePaneDirection "Right"
      },
      {
        key = '${keys.down}',
        mods = 'CTRL',
        action = act.ActivatePaneDirection "Down"
      },
      {
        key = '${keys.up}',
        mods = 'CTRL',
        action = act.ActivatePaneDirection "Up"
      },
      {
        key = 'p',
        mods = 'LEADER',
        action = wezterm.action_callback(build_project_workspace)
      },
      {
        key = 'w',
        mods = 'LEADER',
        action = act.ShowLauncherArgs {
          flags = 'FUZZY|WORKSPACES',
          title = 'Switch Workspace',
        }
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
