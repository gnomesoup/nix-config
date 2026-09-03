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
      keys = {
        focus_pane_left = "prefix+${keys.left}";
        focus_pane_down = "prefix+${keys.down}";
        focus_pane_up = "prefix+${keys.up}";
        focus_pane_right = "prefix+${keys.right}";

        navigate_pane_left = keys.left;
        navigate_pane_down = keys.down;
        navigate_pane_up = keys.up;
        navigate_pane_right = keys.right;
      }
      // lib.optionalAttrs (config.vimBindingKeyboardLayout == "colemak-dh") {
        edit_scrollback = "prefix+shift+e";
        next_tab = "prefix+right";
      };
    };
  };

  home.file = {
    ".pi/agent/extensions/herdr-agent-state.ts".source = "${herdrPiIntegration}/herdr-agent-state.ts";
    ".pi/agent/skills/herdr".source = "${pkgs.herdr}/share/herdr/skills/herdr";
  };
}
