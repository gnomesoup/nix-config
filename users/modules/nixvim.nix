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
      rainbow-delimiters.enable = true;
      telescope.settings.pickers.find_files.hidden = true;
    };
    extraConfigLua = autosaveLua;
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
    ];
    extraConfigVim = ''
      set splitbelow
      set splitright
    '';
  };
}
