{ lib, config, ... }:
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
    colorschemes = {
      tokyonight.enable = lib.mkForce false;
      monokai-pro.enable = true;
    };
    plugins = {
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
          spec = [
            {
              __unkeyed-1 = "<leader>w=";
              icon = {
                icon = "󰆾";
                hl = "WhichKeyIconGreen";
                color = "green";
              };
            }
          ];
        };
      };
      rainbow-delimiters.enable = true;
      telescope.settings.pickers.find_files.hidden = true;
    };
    extraConfigLua = autosaveLua + ''
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
      -- GoToBufferIndex: jump to n-th buffer in tab page
      function GoToBufferIndex(n)
        local buflist = vim.fn.tabpagebuflist(0)
        if not buflist or #buflist == 0 then
          vim.notify("No buffers", vim.log.levels.WARN, { title = "GoToBufferIndex" })
          return
        end
        if n < 1 or n > #buflist then
          vim.notify(("No buffer at index %d"):format(n), vim.log.levels.WARN, { title = "GoToBufferIndex" })
          return
        end
        local target = buflist[n]
        if target and vim.api.nvim_buf_is_valid(target) then
          vim.cmd("buffer " .. tostring(target))
        else
          vim.notify(("Buffer %s is not valid"):format(tostring(target)), vim.log.levels.WARN, { title = "GoToBufferIndex" })
        end
      end
    '';
    keymaps = [
    ]
    ++ normalMaps
    ++ visualMaps
    ++ operatorPendingMaps
    ++ [
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
        action = "<cmd>lua GoToBufferIndex(1)<CR>";
        options = {
          desc = "Go to buffer 1";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>2";
        action = "<cmd>lua GoToBufferIndex(2)<CR>";
        options = {
          desc = "Go to buffer 2";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>3";
        action = "<cmd>lua GoToBufferIndex(3)<CR>";
        options = {
          desc = "Go to buffer 3";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>4";
        action = "<cmd>lua GoToBufferIndex(4)<CR>";
        options = {
          desc = "Go to buffer 4";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>5";
        action = "<cmd>lua GoToBufferIndex(5)<CR>";
        options = {
          desc = "Go to buffer 5";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>6";
        action = "<cmd>lua GoToBufferIndex(6)<CR>";
        options = {
          desc = "Go to buffer 6";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>7";
        action = "<cmd>lua GoToBufferIndex(7)<CR>";
        options = {
          desc = "Go to buffer 7";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>8";
        action = "<cmd>lua GoToBufferIndex(8)<CR>";
        options = {
          desc = "Go to buffer 8";
          silent = true;
        };
      }
      {
        mode = "n";
        key = "<leader>9";
        action = "<cmd>lua GoToBufferIndex(9)<CR>";
        options = {
          desc = "Go to buffer 9";
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
        key = "<leader>qQ";
        action = "<cmd>qa<CR>";
        options = {
          desc = "Quit all";
          silent = true;
        };
      }
    ];
    extraConfigVim = ''
      set splitbelow
      set splitright
    '';
  };
}
