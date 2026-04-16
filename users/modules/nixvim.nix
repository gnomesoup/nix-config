{
  lib,
  config,
  pkgs,
  ...
}:
let
  keys = config.vimBindingKeys;

  mkMap = mode: key: action: {
    inherit mode key action;
  };

  mkNormalMap = key: action: mkMap "n" key action;

  mkVisualMap = key: action: mkMap "v" key action;

  mkOperatorPendingMap = key: action: mkMap "o" key action;

  motionMaps = [
    [
      keys.left
      "h"
    ]
    [
      keys.down
      "j"
    ]
    [
      keys.up
      "k"
    ]
    [
      keys.right
      "l"
    ]
  ];

  textObjectMaps = [
    [
      keys.wordEnd
      "e"
    ]
    [
      keys.WORDend
      "E"
    ]
    [
      keys.findForward
      "f"
    ]
    [
      keys.findBackward
      "F"
    ]
  ];

  normalMaps = builtins.map (pair: mkNormalMap (builtins.elemAt pair 0) (builtins.elemAt pair 1)) (
    motionMaps
    ++ textObjectMaps
    ++ [
      [
        keys.searchNext
        "n"
      ]
      [
        keys.searchPrev
        "N"
      ]
      [
        keys.insert
        "i"
      ]
      [
        keys.insertLineStart
        "I"
      ]
      [
        keys.setMark
        "m"
      ]
    ]
  );

  visualMaps = builtins.map (pair: mkVisualMap (builtins.elemAt pair 0) (builtins.elemAt pair 1)) (
    motionMaps ++ textObjectMaps
  );

  operatorPendingMaps = builtins.map (
    pair: mkOperatorPendingMap (builtins.elemAt pair 0) (builtins.elemAt pair 1)
  ) textObjectMaps;

  autosaveLua = ''
    local autosave_group = vim.api.nvim_create_augroup("nixvim_autosave", { clear = true })

    -- Make eol character show in grey (same as trail/tab)
    vim.cmd("highlight NonText guifg=grey guibg=NONE ctermfg=grey ctermbg=NONE")

    vim.g.autosave_enabled = true

    vim.api.nvim_create_user_command("ToggleAutoSave", function()
      vim.g.autosave_enabled = not vim.g.autosave_enabled
      vim.notify(
        string.format("Autosave %s", vim.g.autosave_enabled and "enabled" or "disabled"),
        vim.log.levels.INFO,
        { title = "nvim" }
      )
    end, {})

    vim.api.nvim_create_autocmd({ "FocusLost", "BufLeave", "InsertLeave" }, {
      group = autosave_group,
      callback = function(args)
        local bufnr = args.buf

        if not vim.g.autosave_enabled then
          return
        end

        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end

        if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
          return
        end

        if vim.api.nvim_buf_get_name(bufnr) == "" or not vim.bo[bufnr].modified then
          return
        end

        vim.api.nvim_buf_call(bufnr, function()
          pcall(vim.cmd, "silent write")
        end)
      end,
    })

    -- Toggle whitespace visibility: shows all spaces as · and EOL as ↲
    vim.api.nvim_create_user_command("ToggleWhitespace", function()
      local listchars = vim.opt.listchars:get()
      local list = vim.opt.list:get()

      if listchars.space then
        -- Turn off: remove space and eol
        vim.opt.listchars = {
          tab = listchars.tab or "» ",
          trail = listchars.trail or "·",
          nbsp = listchars.nbsp or "␣",
        }
        vim.notify("Whitespace hidden", vim.log.levels.INFO, { title = "Whitespace" })
      else
        -- Turn on: add space and eol, ensure list is enabled
        vim.opt.listchars = {
          space = "·",
          tab = listchars.tab or "» ",
          trail = "·",
          eol = "⏎",
          nbsp = listchars.nbsp or "␣",
        }
        if not list then
          vim.opt.list = true
        end
        vim.notify("Whitespace visible", vim.log.levels.INFO, { title = "Whitespace" })
      end
    end, {})

    -- Apply config changes (session is auto-saved by VimLeavePre on quit)
    vim.api.nvim_create_user_command("HomeManagerRebuild", function()
      vim.notify("Applying config...", vim.log.levels.INFO, { title = "Rebuild" })

      -- Determine platform-specific apply command
      local apply_cmd = "sudo darwin-rebuild switch --flake path:$HOME/nix-config#$(scutil --get LocalHostName)"
      if vim.fn.has("unix") == 1 and vim.fn.isdirectory("/run/current-system") == 1 then
        apply_cmd = "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-linux -b backup"
      end

      vim.fn.jobstart(apply_cmd, {
        on_exit = function()
          vim.notify("Config updated. Quit and reopen Neovim to apply.", vim.log.levels.INFO, { title = "Rebuild" })
          vim.cmd("quitall")
        end
      })
    end, {})

    -- Reload lua config without rebuilding (for quick testing)
    vim.api.nvim_create_user_command("ReloadLuaConfig", function()
      vim.cmd("luafile ~/.config/nvim/init.lua")
      vim.notify("Lua config reloaded", vim.log.levels.INFO, { title = "Reload" })
    end, {})

    -- Git-based project sessions
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        local git_root = vim.fn.finddir('.git', vim.loop.cwd())
        if #git_root > 0 then
          local session_path = vim.fn.fnamemodify(git_root, ':p:h') .. "/.nvimsession"
          vim.cmd("mksession! " .. session_path)
        end
      end,
    })

    vim.api.nvim_create_autocmd("VimEnter", {
      callback = function()
        local git_root = vim.fn.finddir('.git', vim.loop.cwd())
        if #git_root > 0 then
          local session_path = vim.fn.fnamemodify(git_root, ':p:h') .. "/.nvimsession"
          if vim.fn.filereadable(session_path) == 1 then
            vim.cmd("source " .. session_path)
          end
        end
      end,
      nested = true,
      once = true,
    })
  '';
in
{
  programs.nixvim = {
    # Personal Colemak-DH overrides layered on top of the kickstart base config.
    enable = true;
    clipboard.providers = {
      "wl-copy".enable = lib.mkForce false;
      xsel.enable = lib.mkForce false;
    };
    opts = {
      expandtab = true;
      tabstop = 4;
      shiftwidth = 4;
      softtabstop = 4;
    };
    colorschemes = {
      tokyonight.enable = lib.mkForce false;
      monokai-pro.enable = lib.mkForce false;
    };
    plugins = {
      colorizer = {
        enable = true;
        lazyLoad.enable = false;
        autoLoad = true;
        settings = {
          filetypes = [ "*" ];
          user_commands = true;
        };
      };
      diffview.enable = true;
      neogit = {
        enable = true;
        settings = {
          integrations.diffview = true;
          mappings.status = {
            "${keys.right}" = "Toggle";
          };
        };
      };
      # which-key settings are defined below (merged into a single block)
      rainbow-delimiters.enable = true;
      telescope.settings.pickers.find_files.hidden = true;
      "which-key" = {
        settings = {
          replace = {
            desc = [
              [
                "<space>"
                "SPACE"
              ]
              [
                "<leader>"
                "SPACE"
              ]
              [
                "<[cC][rR]>"
                "RETURN"
              ]
              [
                "<[tT][aA][bB]>"
                "TAB"
              ]
              [
                "<[bB][sS]>"
                "BACKSPACE"
              ]
            ];
          };
          icons = {
            mappings = true;
            colors = true;
          };
          spec = [
            {
              __unkeyed-1 = "<leader>w=";
              icon = {
                icon = "󰆾";
                hl = "WhichKeyIconGreen";
                color = "green";
              };
            }
            # Move focus left  (<leader>wm)
            {
              __unkeyed-1 = "<leader>w${keys.left}";
              icon = {
                icon = " ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            # Move focus down (<leader>wn)
            {
              __unkeyed-1 = "<leader>w${keys.down}";
              icon = {
                icon = " ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            # Move focus up (<leader>we)
            {
              __unkeyed-1 = "<leader>w${keys.up}";
              icon = {
                icon = " ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            # Move focus right (<leader>wi)
            {
              __unkeyed-1 = "<leader>w${keys.right}";
              icon = {
                icon = " ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            # Move buffer left  (<leader>wm)
            {
              __unkeyed-1 = "<leader>b${keys.left}";
              icon = {
                icon = " ";
                color = "red";
                hl = "WhichKeyIconRed";
              };
            }
            # Move buffer down (<leader>wn)
            {
              __unkeyed-1 = "<leader>b${keys.down}";
              icon = {
                icon = " ";
                color = "red";
                hl = "WhichKeyIconRed";
              };
            }
            # Move buffer up (<leader>we)
            {
              __unkeyed-1 = "<leader>b${keys.up}";
              icon = {
                icon = " ";
                color = "red";
                hl = "WhichKeyIconRed";
              };
            }
            # Move buffer right (<leader>wi)
            {
              __unkeyed-1 = "<leader>b${keys.right}";
              icon = {
                icon = " ";
                color = "red";
                hl = "WhichKeyIconRed";
              };
            }
            {
              __unkeyed-1 = "<leader>1";
              icon = {
                icon = "① ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>2";
              icon = {
                icon = "② ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>3";
              icon = {
                icon = "③ ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>4";
              icon = {
                icon = "④ ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>5";
              icon = {
                icon = "⑤ ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>6";
              icon = {
                icon = "⑥ ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>7";
              icon = {
                icon = "⑦ ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>8";
              icon = {
                icon = "⑧ ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>9";
              icon = {
                icon = "⑨ ";
                color = "green";
                hl = "WhichKeyIconGreen";
              };
            }
            {
              __unkeyed-1 = "<leader>bs";
              icon = {
                icon = "󰈔 ";
                color = "red";
                hl = "WhichKeyIconRed";
              };
            }
            # NeoCodeium: AI completion (c = codeium) - prefix keymap added below
            {
              __unkeyed-1 = "<leader>ct";
              icon = {
                icon = "󰐕 ";
                color = "purple";
                hl = "WhichKeyIconPurple";
              };
            }
            {
              __unkeyed-1 = "<leader>cb";
              icon = {
                icon = "󰐔 ";
                color = "purple";
                hl = "WhichKeyIconPurple";
              };
            }
            {
              __unkeyed-1 = "<leader>ce";
              icon = {
                icon = "󰗤 ";
                color = "purple";
                hl = "WhichKeyIconPurple";
              };
            }
            {
              __unkeyed-1 = "<leader>cd";
              icon = {
                icon = "󰤿 ";
                color = "purple";
                hl = "WhichKeyIconPurple";
              };
            }
            {
              __unkeyed-1 = "<leader>cr";
              icon = {
                icon = "󰑓 ";
                color = "purple";
                hl = "WhichKeyIconPurple";
              };
            }
            {
              __unkeyed-1 = "<leader>co";
              icon = {
                icon = "󰐅 ";
                color = "purple";
                hl = "WhichKeyIconPurple";
              };
            }
            # Flash.nvim: jump navigation (j = jump)
            {
              __unkeyed-1 = "<leader>j";
              icon = {
                icon = "󰛦 ";
                color = "orange";
                hl = "WhichKeyIconOrange";
              };
            }
            {
              __unkeyed-1 = "<leader>jj";
              icon = {
                icon = "󰛦 ";
                color = "orange";
                hl = "WhichKeyIconOrange";
              };
            }
            {
              __unkeyed-1 = "<leader>jw";
              icon = {
                icon = "󰛦 ";
                color = "orange";
                hl = "WhichKeyIconOrange";
              };
            }
            {
              __unkeyed-1 = "<leader>js";
              icon = {
                icon = "󰛦 ";
                color = "orange";
                hl = "WhichKeyIconOrange";
              };
            }
            {
              __unkeyed-1 = "<leader>tc";
              icon = {
                icon = "󱓻 ";
                color = "cyan";
                hl = "WhichKeyIconCyan";
              };
            }
            {
              __unkeyed-1 = "<leader>ts";
              icon = {
                icon = "󰖟 ";
                color = "cyan";
                hl = "WhichKeyIconCyan";
              };
            }
          ];
        };
      };
    };
    # neocodeium: AI completion powered by Windsurf/Codeium
    # https://github.com/monkoose/neocodeium
    extraPlugins = [
      pkgs.vimPlugins.flash-nvim
      pkgs.vimPlugins.gruvbox-nvim
      pkgs.vimPlugins.nvim-scrollbar
      pkgs.vimPlugins.sonokai
      (pkgs.vimUtils.buildVimPlugin {
        pname = "neocodeium";
        version = "v1.16.3";
        src = pkgs.fetchFromGitHub {
          owner = "monkoose";
          repo = "neocodeium";
          rev = "v1.16.3";
          sha256 = "1zr6rrvk00d3gwg7sf1vqd1z1gw2qwl0h08zcbc30x8v0iradsai";
        };
      })
    ];
    extraConfigLua = autosaveLua + ''
      vim.o.background = "dark"
      require("gruvbox").setup({ contrast = "" })
      vim.cmd.colorscheme("gruvbox")

      require("scrollbar").setup({
        handlers = {
          diagnostic = true,
          gitsigns = true,
        },
      })

      require("neocodeium").setup({})

      function _G.InsertTabOrAccept()
        local neocodeium = require("neocodeium")
        local blink = require("blink-cmp")

        if neocodeium.visible() then
          neocodeium.accept()
        elseif blink.is_visible() then
          blink.accept()
        elseif blink.snippet_active() then
          blink.snippet_forward()
        else
          vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "n", false)
        end
      end

      function _G.InsertShiftTabOrCycle()
        local neocodeium = require("neocodeium")
        local blink = require("blink-cmp")

        if blink.is_visible() then
          blink.select_prev()
        elseif blink.snippet_active() then
          blink.snippet_backward()
        else
          neocodeium.cycle_or_complete()
        end
      end

      require("flash").setup({
        labels = "${keys.flashLabels}",
        modes = {
          search = { enabled = true },
          char = {
            keys = { "${keys.findForward}", "${keys.findBackward}", "${keys.tillForward}", "${keys.tillBackward}", ";", "," },
          },
          treesitter = { labels = "${keys.flashLabels}" },
        },
      })

      -- CloseOtherBuffers: delete all loaded buffers except current one (non-destructive)
      function CloseOtherBuffers()
        local cur = vim.api.nvim_get_current_buf()
        local buflist = vim.fn.tabpagebuflist(0)
        for _, bufnr in ipairs(buflist) do
          if bufnr ~= cur and vim.api.nvim_buf_is_loaded(bufnr) then
            local binfo = vim.fn.getbufinfo(bufnr)[1]
            if binfo ~= nil and binfo.loaded and binfo.listed then
              pcall(vim.api.nvim_buf_delete, bufnr, {force = false})
            end
          end
        end
      end
      -- GoToWindowIndex: jump to the n-th visible window in column order
      function _G.GoToWindowIndex(n)
        local wins = vim.api.nvim_tabpage_list_wins(0)
        local ordered = {}

        for _, win in ipairs(wins) do
          local config = vim.api.nvim_win_get_config(win)
          if config.relative == "" then
            local pos = vim.api.nvim_win_get_position(win)
            table.insert(ordered, {
              win = win,
              row = pos[1],
              col = pos[2],
            })
          end
        end

        table.sort(ordered, function(a, b)
          if a.col == b.col then
            return a.row < b.row
          end
          return a.col < b.col
        end)

        if #ordered == 0 then
          vim.notify("No windows", vim.log.levels.WARN, { title = "GoToWindowIndex" })
          return
        end

        if n < 1 or n > #ordered then
          vim.notify(("No window at index %d"):format(n), vim.log.levels.WARN, { title = "GoToWindowIndex" })
          return
        end

        vim.api.nvim_set_current_win(ordered[n].win)
      end

      -- MoveBufferAndFocus: swap the current buffer with the adjacent window and follow it
      function _G.MoveBufferAndFocus(dir)
        local curwin = vim.api.nvim_get_current_win()
        local curbuf = vim.api.nvim_win_get_buf(curwin)
        local curpos = vim.api.nvim_win_get_cursor(curwin)

        local ok, err = pcall(vim.cmd, "wincmd " .. dir)
        if not ok then
          vim.notify(
            "MoveBuffer: can't move to window (" .. tostring(err) .. ")",
            vim.log.levels.WARN,
            { title = "MoveBuffer" }
          )
          return
        end

        local target_win = vim.api.nvim_get_current_win()
        if target_win == curwin then
          vim.notify("MoveBuffer: no window in that direction", vim.log.levels.WARN, { title = "MoveBuffer" })
          return
        end

        local target_buf = vim.api.nvim_win_get_buf(target_win)

        vim.api.nvim_win_set_buf(target_win, curbuf)
        vim.api.nvim_win_set_buf(curwin, target_buf)

        vim.api.nvim_set_current_win(target_win)
        pcall(vim.api.nvim_win_set_cursor, target_win, curpos)
      end
    '';
    keymaps = [
    ]
    ++ normalMaps
    ++ visualMaps
    ++ operatorPendingMaps
    ++ [
      {
        mode = "i";
        key = "<Tab>";
        action = "<cmd>lua _G.InsertTabOrAccept()<CR>";
        options = {
          desc = "Accept completion or insert tab";
          silent = true;
          noremap = true;
        };
      }
      {
        mode = "i";
        key = "<S-Tab>";
        action = "<cmd>lua _G.InsertShiftTabOrCycle()<CR>";
        options = {
          desc = "Cycle completion or AI suggestion";
          silent = true;
          noremap = true;
        };
      }
      {
        mode = "i";
        key = "<C-w>";
        action = "<cmd>lua require('neocodeium').accept_word()<CR>";
        options = {
          desc = "Accept word from neocodeium";
          silent = true;
          noremap = true;
        };
      }
      {
        mode = "i";
        key = "<C-a>";
        action = "<cmd>lua require('neocodeium').accept_line()<CR>";
        options = {
          desc = "Accept line from neocodeium";
          silent = true;
          noremap = true;
        };
      }
      {
        mode = "i";
        key = "<C-e>";
        action = "<cmd>lua require('neocodeium').clear()<CR>";
        options = {
          desc = "Clear neocodeium suggestion";
          silent = true;
          noremap = true;
        };
      }
      # NeoCodeium prefix
      {
        mode = "n";
        key = "<leader>c";
        action = "<Nop>";
        options = {
          desc = "[C]ompletions";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>${keys.git}";
        action = "<cmd>Neogit<CR>";
        options = {
          desc = "Open Neogit";
          silent = true;
        };
      }
      {
        mode = "i";
        key = "<A-${keys.findForward}>";
        action = "<cmd>lua require('neocodeium').accept()<CR>";
        options = {
          desc = "Accept neocodeium suggestion";
          silent = true;
        };
      }
      {
        mode = "i";
        key = "<A-${keys.wordEnd}>";
        action = "<cmd>lua require('neocodeium').accept_word()<CR>";
        options = {
          desc = "Accept word from neocodeium";
          silent = true;
        };
      }
      {
        mode = "i";
        key = "<A-a>";
        action = "<cmd>lua require('neocodeium').accept_line()<CR>";
        options = {
          desc = "Accept line from neocodeium";
          silent = true;
        };
      }
      {
        mode = "i";
        key = "<A-${keys.down}>";
        action = "<cmd>lua require('neocodeium').cycle_or_complete()<CR>";
        options = {
          desc = "Cycle/complete neocodeium suggestion";
          silent = true;
        };
      }
      {
        mode = "i";
        key = "<A-${keys.up}>";
        action = "<cmd>lua require('neocodeium').cycle_or_complete(-1)<CR>";
        options = {
          desc = "Cycle neocodeium suggestion reverse";
          silent = true;
        };
      }
      {
        mode = "i";
        key = "<A-${keys.right}>";
        action = "<cmd>lua require('neocodeium').clear()<CR>";
        options = {
          desc = "Clear neocodeium suggestion";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>ta";
        action = "<cmd>ToggleAutoSave<CR>";
        options = {
          desc = "Toggle [A]utosave";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>tw";
        action = "<cmd>ToggleWhitespace<CR>";
        options = {
          desc = "Toggle [W]hitespace visibility";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>tc";
        action = "<cmd>ColorizerToggle<CR>";
        options = {
          desc = "Toggle [C]olorizer";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>ts";
        action = "<cmd>ScrollbarToggle<CR>";
        options = {
          desc = "Toggle [S]crollbar";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>qr";
        action = "<cmd>ReloadLuaConfig<CR>";
        options = {
          desc = "[R]eload lua config";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>qR";
        action = "<cmd>HomeManagerRebuild<CR>";
        options = {
          desc = "[R]ebuild home-manager and restart";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>w";
        action = "<Nop>";
        options = {
          desc = "[W]indow";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>ws";
        action = "<cmd>split<CR>";
        options = {
          desc = "Horizontal window split";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>wv";
        action = "<cmd>vsplit<CR>";
        options = {
          desc = "Vertical window split";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>w=";
        action = "<cmd>wincmd =<CR>";
        options = {
          desc = "Equalize window sizes";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>w${keys.left}";
        action = "<cmd>wincmd h<CR>";
        options = {
          desc = "Focus left window";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>w${keys.down}";
        action = "<cmd>wincmd j<CR>";
        options = {
          desc = "Focus down window";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>w${keys.up}";
        action = "<cmd>wincmd k<CR>";
        options = {
          desc = "Focus up window";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>w${keys.right}";
        action = "<cmd>wincmd l<CR>";
        options = {
          desc = "Focus right window";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>b";
        action = "<Nop>";
        options = {
          desc = "[B]uffer";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>bd";
        action = "<cmd>bdelete<CR>";
        options = {
          desc = "Delete current buffer";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>bM";
        action = "<cmd>lua CloseOtherBuffers()<CR>";
        options = {
          desc = "Close other buffers (non-destructive)";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>bs";
        action = "<cmd>vnew<CR>";
        options = {
          desc = "Scratch buffer (vertical)";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>jj";
        action = "<cmd>lua require('flash').jump()<CR>";
        options = {
          desc = "Flash jump (char)";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>jw";
        action = "<cmd>lua require('flash').treesitter()<CR>";
        options = {
          desc = "Flash treesitter (word)";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>js";
        action = "<cmd>lua require('flash').toggle()<CR>";
        options = {
          desc = "Toggle flash search";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>b${keys.left}";
        action = "<cmd>lua _G.MoveBufferAndFocus('h')<CR>";
        options = {
          desc = "Move buffer left";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>b${keys.down}";
        action = "<cmd>lua _G.MoveBufferAndFocus('j')<CR>";
        options = {
          desc = "Move buffer down";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>b${keys.up}";
        action = "<cmd>lua _G.MoveBufferAndFocus('k')<CR>";
        options = {
          desc = "Move buffer up";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>b${keys.right}";
        action = "<cmd>lua _G.MoveBufferAndFocus('l')<CR>";
        options = {
          desc = "Move buffer right";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader><Tab>";
        action = "<cmd>b#<CR>";
        options = {
          desc = "Switch to last buffer";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>1";
        action = "<cmd>lua _G.GoToWindowIndex(1)<CR>";
        options = {
          desc = "Go to window 1";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>2";
        action = "<cmd>lua _G.GoToWindowIndex(2)<CR>";
        options = {
          desc = "Go to window 2";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>3";
        action = "<cmd>lua _G.GoToWindowIndex(3)<CR>";
        options = {
          desc = "Go to window 3";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>4";
        action = "<cmd>lua _G.GoToWindowIndex(4)<CR>";
        options = {
          desc = "Go to window 4";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>5";
        action = "<cmd>lua _G.GoToWindowIndex(5)<CR>";
        options = {
          desc = "Go to window 5";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>6";
        action = "<cmd>lua _G.GoToWindowIndex(6)<CR>";
        options = {
          desc = "Go to window 6";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>7";
        action = "<cmd>lua _G.GoToWindowIndex(7)<CR>";
        options = {
          desc = "Go to window 7";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>8";
        action = "<cmd>lua _G.GoToWindowIndex(8)<CR>";
        options = {
          desc = "Go to window 8";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>9";
        action = "<cmd>lua _G.GoToWindowIndex(9)<CR>";
        options = {
          desc = "Go to window 9";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>q";
        action = "<Nop>";
        options = {
          desc = "[Q]uit";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>qq";
        action = "<cmd>q<CR>";
        options = {
          desc = "Quit the frame";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>qa";
        action = "<cmd>qa<CR>";
        options = {
          desc = "Quit all";
          silent = true;
        };
      }
      # NeoCodeium commands
      {
        mode = "n";
        key = "<leader>ct";
        action = "<cmd>NeoCodeium toggle<CR>";
        options = {
          desc = "Toggle NeoCodeium globally";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>cb";
        action = "<cmd>NeoCodeium toggle_buffer<CR>";
        options = {
          desc = "Toggle NeoCodeium for buffer";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>ce";
        action = "<cmd>NeoCodeium enable<CR>";
        options = {
          desc = "Enable NeoCodeium globally";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>cd";
        action = "<cmd>NeoCodeium disable<CR>";
        options = {
          desc = "Disable NeoCodeium globally";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>cr";
        action = "<cmd>NeoCodeium restart<CR>";
        options = {
          desc = "Restart NeoCodeium server";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>co";
        action = "<cmd>NeoCodeium open_log<CR>";
        options = {
          desc = "Open NeoCodeium log";
          silent = true;
        };
      }
    ];
    extraConfigVim = ''
      set background=dark
      set splitbelow
      set splitright

      autocmd FileType nix setlocal expandtab tabstop=2 shiftwidth=2 softtabstop=2
    '';
  };
}
