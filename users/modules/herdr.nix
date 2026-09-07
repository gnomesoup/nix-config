{
  config,
  lib,
  pkgs,
  ...
}:
let
  keys = config.vimBindingKeys;
  herdrPiIntegration = pkgs.runCommand "herdr-pi-integration" { } ''
    export HOME="$TMPDIR/home"
    export PI_CODING_AGENT_DIR="$TMPDIR/pi"

    mkdir -p "$HOME" "$PI_CODING_AGENT_DIR/extensions"
    ${lib.getExe pkgs.herdr} integration install pi

    mkdir -p "$out"
    cp "$PI_CODING_AGENT_DIR/extensions/herdr-agent-state.ts" "$out/herdr-agent-state.ts"
  '';
in
{
  programs.herdr = {
    enable = true;
    package = pkgs.herdr;
    settings = {
      onboarding = false;
      update = {
        version_check = false;
        manifest_check = false;
      };
      ui.toast = {
        delivery = "herdr";
        delay_seconds = 1;
        herdr.position = "bottom-right";
      };
      keys = {
        switch_workspace = lib.mkDefault "super+1..9";
        copy_mode = "prefix+c";
        edit_scrollback = "prefix+shift+e";
        new_tab = "prefix+t";

        focus_pane_left = "prefix+${keys.left}";
        focus_pane_down = "prefix+${keys.down}";
        focus_pane_up = "prefix+${keys.up}";
        focus_pane_right = "prefix+${keys.right}";

        swap_pane_left = "prefix+alt+${keys.left}";
        swap_pane_down = "prefix+alt+${keys.down}";
        swap_pane_up = "prefix+alt+${keys.up}";
        swap_pane_right = "prefix+alt+${keys.right}";

        navigate_pane_left = keys.left;
        navigate_pane_down = keys.down;
        navigate_pane_up = keys.up;
        navigate_pane_right = keys.right;

        command = [
          {
            key = "ctrl+${keys.left}";
            type = "plugin_action";
            command = "herdr-nvim-nav.left";
          }
          {
            key = "ctrl+${keys.down}";
            type = "plugin_action";
            command = "herdr-nvim-nav.down";
          }
          {
            key = "ctrl+${keys.up}";
            type = "plugin_action";
            command = "herdr-nvim-nav.up";
          }
          {
            key = "ctrl+${keys.right}";
            type = "plugin_action";
            command = "herdr-nvim-nav.right";
          }
        ];
      }
      // lib.optionalAttrs (config.vimBindingKeyboardLayout == "colemak-dh") {
        next_tab = "prefix+right";
      };
    };
  };

  home.activation.linkHerdrNvimNav = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD ${lib.getExe pkgs.herdr} plugin link ${lib.escapeShellArg "${pkgs.herdr-nvim-nav}"}
  '';

  home.file = {
    ".pi/agent/extensions/herdr-agent-state.ts".source = "${herdrPiIntegration}/herdr-agent-state.ts";
    ".pi/agent/skills/herdr".source = "${pkgs.herdr}/share/herdr/skills/herdr";
  };
}
