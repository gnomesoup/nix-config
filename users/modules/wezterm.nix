{ pkgs, config, ... }:
let
  keys = config.vimBindingKeys;
  weztermLua = ''
    local wezterm = require "wezterm"
    local act = wezterm.action
    local mux = wezterm.mux
    local is_windows = wezterm.target_triple:find("windows") ~= nil
    local local_mux_domain = "local_mux"

    local config = wezterm.config_builder and wezterm.config_builder() or {}

    local function trim(text)
      if not text then
        return nil
      end

      return text:gsub("^%s+", ""):gsub("%s+$", "")
    end

    local function escape_pattern(text)
      return text:gsub("([^%w])", "%%%1")
    end

    local function display_path(path)
      if not path then
        return ""
      end

      local home = os.getenv("HOME") or wezterm.home_dir
      if home and home ~= "" then
        if path == home then
          return "~"
        end

        path = path:gsub("^" .. escape_pattern(home) .. "/", "~/")
      end

      return path
    end

    local function url_decode(text)
      if not text then
        return nil
      end

      return text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
      end)
    end

    local function notify(window, message)
      window:toast_notification("WezTerm Projects", message, nil, 4000)
    end

    local function is_local_file_url(url)
      return url
        and url.scheme == "file"
        and (url.host == nil or url.host == "" or url.host == "localhost" or url.host == wezterm.hostname())
    end

    local function pane_cwd_url(pane)
      local cwd = pane:get_current_working_dir()
      if not cwd then
        return nil, "Current pane has no working directory"
      end

      if type(cwd) == "string" then
        cwd = wezterm.url.parse(cwd)
      end

      return cwd, nil
    end

    local function wsl_context(cwd, domain_name)
      local distro = domain_name:match("^WSL:(.+)$")
      if not distro then
        return nil, nil
      end

      local path = url_decode(cwd.path or "")
      local host = (cwd.host or ""):lower()

      if host == "wsl.localhost" or host == "wsl$" then
        local parsed_distro, linux_path = path:match("^/([^/]+)(/.*)$")
        if not parsed_distro or not linux_path then
          return nil, "Could not determine the WSL project path"
        end

        distro = parsed_distro
        path = linux_path
      end

      if not path or path == "" then
        return nil, "Could not determine the WSL project path"
      end

      local drive, rest = path:match("^([A-Za-z]):(.*)$")
      if drive and rest then
        path = "/mnt/" .. drive:lower() .. rest
      end

      return {
        kind = "wsl",
        cwd = path,
        distro = distro,
        domain_name = domain_name,
      }, nil
    end

    local function pane_context(pane)
      local cwd, cwd_error = pane_cwd_url(pane)
      if not cwd then
        return nil, cwd_error
      end

      local domain_name = pane:get_domain_name()
      local wsl, wsl_error = wsl_context(cwd, domain_name)
      if wsl then
        return wsl, nil
      end

      if wsl_error then
        return nil, wsl_error
      end

      if is_local_file_url(cwd) then
        return {
          kind = "local",
          cwd = cwd.file_path,
          domain_name = domain_name,
        }, nil
      end

      return nil, "Project launcher only supports local or WSL panes"
    end

    local function git_root_from_user_vars(pane)
      local user_vars = pane:get_user_vars() or {}
      local git_root = trim(user_vars.git_root)

      if git_root == nil or git_root == "" then
        return nil
      end

      return git_root
    end

    local function git_root_for_context(context)
      local command
      if context.kind == "wsl" then
        command = {
          "wsl.exe",
          "-d",
          context.distro,
          "-e",
          "git",
          "-C",
          context.cwd,
          "rev-parse",
          "--show-toplevel",
        }
      else
        command = {
          "git",
          "-C",
          context.cwd,
          "rev-parse",
          "--show-toplevel",
        }
      end

      local success, stdout = wezterm.run_child_process(command)
      if not success then
        return nil
      end

      return trim(stdout)
    end

    local function git_root_for_pane(pane)
      local git_root = git_root_from_user_vars(pane)
      if git_root then
        return git_root
      end

      local context = pane_context(pane)
      if not context then
        return nil
      end

      return git_root_for_context(context)
    end

    local read_recent_projects

    local function project_name_for_root(git_root, domain_name)
      local project_name = git_root:match("([^/\\]+)$")
      if not project_name or project_name == "" then
        return nil
      end

      if read_recent_projects then
        for _, recent_project in ipairs(read_recent_projects()) do
          if recent_project.root == git_root and recent_project.domain_name == domain_name then
            return recent_project.name
          end
        end
      end

      return project_name
    end

    local function project_info_for_pane(pane)
      local context, context_error = pane_context(pane)
      if not context then
        return nil, context_error
      end

      local git_root = git_root_from_user_vars(pane) or git_root_for_context(context)
      if not git_root then
        return nil, "Current pane is not inside a git project"
      end

      local project_name = project_name_for_root(git_root, context.domain_name)
      if not project_name then
        return nil, "Could not determine project name"
      end

      return {
        name = project_name,
        root = git_root,
        kind = context.kind,
        domain_name = context.domain_name,
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
              local git_root = git_root_for_pane(pane)
              if git_root then
                roots[git_root] = true
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

    local function workspace_name_for_root(root)
      for _, workspace_name in ipairs(mux.get_workspace_names()) do
        local existing_root = single_workspace_root(workspace_name)
        if existing_root == root then
          return workspace_name
        end
      end

      return nil
    end

    local function rename_workspace(old_name, new_name)
      if old_name == new_name then
        return true, nil
      end

      if workspace_exists(new_name) then
        return false, "target exists"
      end

      if type(mux.rename_workspace) ~= "function" then
        return false, "not supported by this WezTerm build"
      end

      local ok, err = pcall(function()
        mux.rename_workspace(old_name, new_name)
      end)
      if not ok then
        return false, tostring(err)
      end

      return true, nil
    end

    local function shell_line_in_dir(dir, command)
      local quoted_dir = wezterm.shell_quote_arg(dir)
      local wrapped_command = "cd " .. quoted_dir

      if command and command ~= "" then
        wrapped_command = wrapped_command .. " && " .. command
      end

      return wrapped_command .. "\n"
    end

    local recent_projects_dir = (os.getenv("XDG_STATE_HOME") or (wezterm.home_dir .. "/.local/state")) .. "/wezterm"
    local recent_projects_file = recent_projects_dir .. "/recent-projects.json"
    local max_recent_projects = 20

    local function ensure_recent_projects_dir()
      if is_windows then
        wezterm.run_child_process {
          "powershell.exe",
          "-NoProfile",
          "-Command",
          "& { param($path) New-Item -ItemType Directory -Force -Path $path | Out-Null }",
          recent_projects_dir,
        }
      else
        wezterm.run_child_process { "mkdir", "-p", recent_projects_dir }
      end
    end

    local function normalize_recent_project(project)
      if type(project) ~= "table" or type(project.name) ~= "string" or type(project.root) ~= "string" then
        return nil
      end

      local name = trim(project.name)
      if not name or name == "" then
        return nil
      end

      return {
        name = name,
        root = project.root,
        kind = project.kind,
        domain_name = project.domain_name,
      }
    end

    local function same_recent_project(left, right)
      return left
        and right
        and left.root == right.root
        and left.domain_name == right.domain_name
    end

    function read_recent_projects()
      local file = io.open(recent_projects_file, "r")
      if not file then
        return {}
      end

      local contents = file:read("*a")
      file:close()

      local ok, decoded = pcall(wezterm.json_parse, contents)
      if not ok or type(decoded) ~= "table" then
        return {}
      end

      local projects = {}
      for _, project in ipairs(decoded) do
        local normalized = normalize_recent_project(project)
        if normalized then
          table.insert(projects, normalized)
        end
      end

      return projects
    end

    local function write_recent_projects(projects)
      local ok, encoded = pcall(wezterm.json_encode, projects)
      if not ok then
        return
      end

      ensure_recent_projects_dir()

      local file = io.open(recent_projects_file, "w")
      if not file then
        return
      end

      file:write(encoded)
      file:close()
    end

    local function remember_project(project)
      local normalized = normalize_recent_project(project)
      if not normalized then
        return
      end

      local projects = read_recent_projects()
      local deduped = { normalized }

      for _, recent_project in ipairs(projects) do
        if not same_recent_project(recent_project, normalized) then
          table.insert(deduped, recent_project)
        end

        if #deduped >= max_recent_projects then
          break
        end
      end

      write_recent_projects(deduped)
    end

    local function rename_recent_project(project, new_name)
      local normalized = normalize_recent_project(project)
      local name = trim(new_name)
      if not normalized or not name or name == "" then
        return false
      end

      local projects = read_recent_projects()
      local updated = false
      for _, recent_project in ipairs(projects) do
        if same_recent_project(recent_project, normalized) then
          recent_project.name = name
          updated = true
          break
        end
      end

      if not updated then
        normalized.name = name
        table.insert(projects, 1, normalized)
      end

      write_recent_projects(projects)
      return true
    end

    local function delete_recent_project(project)
      local normalized = normalize_recent_project(project)
      if not normalized then
        return false
      end

      local projects = read_recent_projects()
      local filtered = {}
      local removed = false

      for _, recent_project in ipairs(projects) do
        if same_recent_project(recent_project, normalized) then
          removed = true
        else
          table.insert(filtered, recent_project)
        end
      end

      if removed then
        write_recent_projects(filtered)
      end

      return removed
    end

    local function open_project_workspace(window, pane, project)
      local existing_workspace = workspace_exists(project.name)
      local existing_root, root_error = single_workspace_root(project.name)

      remember_project(project)

      local project_workspace = workspace_name_for_root(project.root)
      if project_workspace and project_workspace ~= project.name then
        if existing_workspace then
          notify(window, "Workspace '" .. project.name .. "' already exists for another project")
          return
        end

        local renamed, rename_error = rename_workspace(project_workspace, project.name)
        if renamed then
          window:perform_action(act.SwitchToWorkspace { name = project.name }, pane)
        else
          notify(
            window,
            "Using workspace '" .. project_workspace .. "'; rename failed: " .. (rename_error or "unknown error")
          )
          window:perform_action(act.SwitchToWorkspace { name = project_workspace }, pane)
        end
        return
      end

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

      local spawn_window = {
        workspace = project.name,
      }
      if project.domain_name then
        spawn_window.domain = { DomainName = project.domain_name }
      end

      local tab, editor_pane, mux_window = mux.spawn_window(spawn_window)
      if not tab or not editor_pane or not mux_window then
        notify(window, "Failed to create workspace '" .. project.name .. "'")
        return
      end

      tab:set_title(project.name)

      local bottom_pane
      local bottom_ok, bottom_err = pcall(function()
        bottom_pane = editor_pane:split {
          direction = "Bottom",
          top_level = true,
          size = 12,
        }
      end)
      if not bottom_ok then
        notify(window, "Failed to create bottom pane: " .. tostring(bottom_err))
        return
      end

      local side_pane
      local right_ok, right_err = pcall(function()
        side_pane = editor_pane:split {
          direction = "Right",
          size = 0.25,
        }
      end)
      if not right_ok then
        notify(window, "Failed to create side pane: " .. tostring(right_err))
        return
      end

      wezterm.sleep_ms(50)
      editor_pane:send_text(shell_line_in_dir(project.root, "nvim"))
      if bottom_pane then
        bottom_pane:send_text(shell_line_in_dir(project.root, nil))
      end
      if side_pane then
        side_pane:send_text(shell_line_in_dir(project.root, "pi"))
      end

      window:perform_action(act.SwitchToWorkspace { name = project.name }, pane)
      editor_pane:activate()
    end

    local function build_project_workspace(window, pane)
      local project, project_error = project_info_for_pane(pane)
      if not project then
        notify(window, project_error)
        return
      end

      open_project_workspace(window, pane, project)
    end

    local selector_colors = {
      active_project = "#50fa7b",
      inactive_project = "#a389d8",
      workspace = "#50fa7b",
    }

    local function selector_label(parts)
      local formatted = {}

      for _, part in ipairs(parts) do
        if part.color then
          table.insert(formatted, { Foreground = { Color = part.color } })
        end
        if part.bold then
          table.insert(formatted, { Attribute = { Intensity = "Bold" } })
        end
        table.insert(formatted, { Text = part.text })
        if part.bold or part.color then
          table.insert(formatted, "ResetAttributes")
        end
      end

      return wezterm.format(formatted)
    end

    local function project_choice_label(project, is_active)
      local name_color = is_active and selector_colors.active_project or selector_colors.inactive_project
      local parts = {
        { text = "󰉋 " },
        { text = project.name, color = name_color, bold = true },
      }

      if is_active then
        table.insert(parts, { text = "  ●" })
      end

      table.insert(parts, { text = "  " .. display_path(project.root) })

      if project.domain_name then
        table.insert(parts, { text = "  @" .. project.domain_name })
      end

      table.insert(parts, { text = "  project" })
      return selector_label(parts)
    end

    local function workspace_choice_label(workspace_name)
      return selector_label {
        { text = "󱂬 " },
        { text = workspace_name, color = selector_colors.workspace, bold = true },
        { text = "  workspace" },
      }
    end

    local function show_workspace_or_project_launcher(window, pane)
      local choices = {}
      local active_workspaces = {}
      local shown_workspaces = {}
      local workspace_names = mux.get_workspace_names()

      for _, workspace_name in ipairs(workspace_names) do
        active_workspaces[workspace_name] = true
      end

      local recent_projects = read_recent_projects()
      for index, project in ipairs(recent_projects) do
        local is_active = false
        if active_workspaces[project.name] then
          local existing_root = single_workspace_root(project.name)
          if existing_root == project.root then
            is_active = true
            shown_workspaces[project.name] = true
          end
        end

        table.insert(choices, {
          id = "recent:" .. index,
          label = project_choice_label(project, is_active),
        })
      end

      table.sort(workspace_names)
      for _, workspace_name in ipairs(workspace_names) do
        if not shown_workspaces[workspace_name] then
          table.insert(choices, {
            id = "workspace:" .. workspace_name,
            label = workspace_choice_label(workspace_name),
          })
        end
      end

      if #choices == 0 then
        notify(window, "No workspaces or recent projects")
        return
      end

      window:perform_action(
        act.InputSelector {
          title = "Projects / Workspaces",
          description = "Type a project name or path. Saved projects are listed before plain workspaces.",
          fuzzy_description = "Fuzzy search by project name, path, domain, or workspace name.",
          fuzzy = true,
          choices = choices,
          action = wezterm.action_callback(function(selector_window, selector_pane, id, label)
            if not id then
              return
            end

            local recent_index = tonumber(id:match("^recent:(%d+)$"))
            local recent_project = recent_index and read_recent_projects()[recent_index]
            if recent_project then
              open_project_workspace(selector_window, selector_pane, recent_project)
              return
            end

            local workspace_name = id:match("^workspace:(.*)$")
            if workspace_name then
              selector_window:perform_action(act.SwitchToWorkspace { name = workspace_name }, selector_pane)
            end
          end),
        },
        pane
      )
    end

    local function prompt_rename_saved_project(window, pane, project)
      window:perform_action(
        act.PromptInputLine {
          description = "Rename saved project '" .. project.name .. "' (current path: " .. display_path(project.root) .. ")",
          action = wezterm.action_callback(function(prompt_window, prompt_pane, line)
            local new_name = trim(line)
            if not new_name or new_name == "" then
              return
            end

            local old_name = project.name
            if not rename_recent_project(project, new_name) then
              notify(prompt_window, "Could not rename saved project")
              return
            end

            local active_workspace = workspace_name_for_root(project.root)
            if active_workspace and active_workspace ~= new_name then
              local renamed, rename_error = rename_workspace(active_workspace, new_name)
              if not renamed then
                notify(
                  prompt_window,
                  "Saved rename; active workspace rename failed: " .. (rename_error or "unknown error")
                )
                return
              end
            end

            notify(prompt_window, "Renamed saved project '" .. old_name .. "' to '" .. new_name .. "'")
          end),
        },
        pane
      )
    end

    local function show_saved_project_actions(window, pane, project)
      window:perform_action(
        act.InputSelector {
          title = "Manage " .. project.name,
          description = display_path(project.root),
          choices = {
            { id = "open", label = "open    " .. project_choice_label(project, false) },
            { id = "rename", label = "rename  " .. project_choice_label(project, false) },
            { id = "delete", label = "delete  " .. project_choice_label(project, false) },
          },
          action = wezterm.action_callback(function(action_window, action_pane, id, label)
            if id == "open" then
              open_project_workspace(action_window, action_pane, project)
            elseif id == "rename" then
              prompt_rename_saved_project(action_window, action_pane, project)
            elseif id == "delete" then
              if delete_recent_project(project) then
                notify(action_window, "Deleted saved project '" .. project.name .. "'")
              else
                notify(action_window, "Saved project was already gone")
              end
            end
          end),
        },
        pane
      )
    end

    local function show_saved_project_manager(window, pane)
      local recent_projects = read_recent_projects()
      if #recent_projects == 0 then
        notify(window, "No saved projects")
        return
      end

      local choices = {}
      for index, project in ipairs(recent_projects) do
        table.insert(choices, {
          id = "project:" .. index,
          label = project_choice_label(project, false),
        })
      end

      window:perform_action(
        act.InputSelector {
          title = "Manage Saved Projects",
          description = "Select a saved project to open, rename, or delete.",
          fuzzy_description = "Fuzzy search by project name, path, or domain.",
          fuzzy = true,
          choices = choices,
          action = wezterm.action_callback(function(manager_window, manager_pane, id, label)
            if not id then
              return
            end

            local project_index = tonumber(id:match("^project:(%d+)$"))
            local project = project_index and read_recent_projects()[project_index]
            if project then
              show_saved_project_actions(manager_window, manager_pane, project)
            end
          end),
        },
        pane
      )
    end

    local function detach_remote_domain(window, pane)
      local domain_name = pane:get_domain_name()
      if domain_name == "local" or domain_name == local_mux_domain or domain_name:match("^WSL:") then
        notify(window, "Detach is only intended for attached remote domains")
        return
      end

      window:perform_action(act.DetachDomain "CurrentPaneDomain", pane)
    end

    wezterm.on("mux-startup", function()
      if is_windows then
        local domain = mux.get_domain("WSL:NixOS")
        if domain then
          mux.set_default_domain(domain)
        end
      end
    end)

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
    config.command_palette_bg_color = "#292b2e"
    config.command_palette_fg_color = "#bbc2cf"
    config.command_palette_font_size = 16.0
    config.command_palette_rows = 12
    config.colors = {
      cursor_bg = "#d1951d",
      cursor_border = "#d1951d",
      cursor_fg = "#292b2e",
      selection_bg = "#34363b",
      selection_fg = "#bbc2cf",
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
      config.wsl_domains = {
        {
          name = "WSL:NixOS",
          distribution = "NixOS",
          default_cwd = "~",
        }
      }
      config.default_domain = "WSL:NixOS"
      config.default_mux_server_domain = "WSL:NixOS"
    else
      config.unix_domains = {
        {
          name = local_mux_domain,
        },
      }
      config.default_gui_startup_args = { "connect", local_mux_domain }
    end

    config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }
    config.quick_select_alphabet = '${keys.flashLabels}'

    local ssh_domains = {}
    -- Use enumerate_ssh_hosts with explicit paths (default_ssh_domains has a bug with Include directive)
    local home_dir = os.getenv("HOME") or wezterm.home_dir
    local hosts = wezterm.enumerate_ssh_hosts(
      home_dir .. "/.ssh/config",
      home_dir .. "/.ssh/config.d/remote.conf"
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

    local function key_id(key, mods)
      return key .. ":" .. (mods or "NONE")
    end

    local function remove_bindings(bindings, removals)
      local filtered = {}
      for _, binding in ipairs(bindings) do
        if not removals[key_id(binding.key, binding.mods)] then
          table.insert(filtered, binding)
        end
      end

      return filtered
    end

    local function add_binding(bindings, key, mods, action)
      table.insert(bindings, { key = key, mods = mods, action = action })
    end

    local key_tables = wezterm.gui.default_key_tables()

    key_tables.copy_mode = remove_bindings(key_tables.copy_mode or {}, {
      [key_id('h', 'NONE')] = true,
      [key_id('h', 'ALT')] = true,
      [key_id('j', 'NONE')] = true,
      [key_id('k', 'NONE')] = true,
      [key_id('l', 'NONE')] = true,
      [key_id('e', 'NONE')] = true,
      [key_id('f', 'NONE')] = true,
      [key_id('F', 'NONE')] = true,
      [key_id('F', 'SHIFT')] = true,
      [key_id('t', 'NONE')] = true,
      [key_id('T', 'NONE')] = true,
      [key_id('T', 'SHIFT')] = true,
      [key_id('${keys.left}', 'NONE')] = true,
      [key_id('${keys.left}', 'ALT')] = true,
      [key_id('${keys.down}', 'NONE')] = true,
      [key_id('${keys.up}', 'NONE')] = true,
      [key_id('${keys.right}', 'NONE')] = true,
      [key_id('${keys.wordEnd}', 'NONE')] = true,
      [key_id('${keys.findForward}', 'NONE')] = true,
      [key_id('${keys.findBackward}', 'NONE')] = true,
      [key_id('${keys.findBackward}', 'SHIFT')] = true,
      [key_id('${keys.tillForward}', 'NONE')] = true,
      [key_id('${keys.tillBackward}', 'NONE')] = true,
      [key_id('${keys.tillBackward}', 'SHIFT')] = true,
    })
    add_binding(key_tables.copy_mode, '${keys.left}', 'NONE', act.CopyMode 'MoveLeft')
    add_binding(key_tables.copy_mode, '${keys.left}', 'ALT', act.CopyMode 'MoveBackwardWord')
    add_binding(key_tables.copy_mode, '${keys.down}', 'NONE', act.CopyMode 'MoveDown')
    add_binding(key_tables.copy_mode, '${keys.up}', 'NONE', act.CopyMode 'MoveUp')
    add_binding(key_tables.copy_mode, '${keys.right}', 'NONE', act.CopyMode 'MoveRight')
    add_binding(key_tables.copy_mode, '${keys.wordEnd}', 'NONE', act.CopyMode 'MoveForwardWordEnd')
    add_binding(key_tables.copy_mode, '${keys.findForward}', 'NONE', act.CopyMode { JumpForward = { prev_char = false } })
    add_binding(key_tables.copy_mode, '${keys.findBackward}', 'NONE', act.CopyMode { JumpBackward = { prev_char = false } })
    add_binding(key_tables.copy_mode, '${keys.findBackward}', 'SHIFT', act.CopyMode { JumpBackward = { prev_char = false } })
    add_binding(key_tables.copy_mode, '${keys.tillForward}', 'NONE', act.CopyMode { JumpForward = { prev_char = true } })
    add_binding(key_tables.copy_mode, '${keys.tillBackward}', 'NONE', act.CopyMode { JumpBackward = { prev_char = true } })
    add_binding(key_tables.copy_mode, '${keys.tillBackward}', 'SHIFT', act.CopyMode { JumpBackward = { prev_char = true } })

    key_tables.search_mode = remove_bindings(key_tables.search_mode or {}, {
      [key_id('${keys.searchNext}', 'NONE')] = true,
      [key_id('${keys.searchPrev}', 'NONE')] = true,
    })
    add_binding(key_tables.search_mode, '${keys.searchNext}', 'NONE', act.CopyMode 'NextMatch')
    add_binding(key_tables.search_mode, '${keys.searchPrev}', 'NONE', act.CopyMode 'PriorMatch')

    key_tables.resize_pane = {
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
    }
    config.key_tables = key_tables

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
        key = 's',
        mods = 'CTRL|SHIFT',
        action = act.PaneSelect { mode = 'Activate' }
      },
      {
        key = 'q',
        mods = 'LEADER',
        action = act.QuickSelect
      },
      {
        key = 'p',
        mods = 'LEADER',
        action = wezterm.action_callback(show_workspace_or_project_launcher)
      },
      {
        key = 'P',
        mods = 'LEADER|SHIFT',
        action = wezterm.action_callback(show_saved_project_manager)
      },
      {
        key = 'w',
        mods = 'LEADER',
        action = wezterm.action_callback(build_project_workspace)
      },
      {
        key = 'd',
        mods = 'LEADER',
        action = act.ShowLauncherArgs {
          flags = 'FUZZY|DOMAINS',
          title = 'Attach Domain',
        }
      },
      {
        key = 'D',
        mods = 'LEADER|SHIFT',
        action = wezterm.action_callback(detach_remote_domain)
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
