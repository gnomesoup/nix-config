{
  config,
  lib,
  pkgs,
  ...
}:
let
  jsonFormat = pkgs.formats.json { };
  piNpmPrefix = "${config.home.homeDirectory}/.pi/agent/npm-global";
  piNpm = pkgs.writeShellApplication {
    name = "pi-npm";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      exec ${pkgs.nodejs}/bin/npm --prefix ${lib.escapeShellArg piNpmPrefix} "$@"
    '';
  };
  piSettings = {
    defaultModel = "gpt-5.5";
    defaultProvider = "openai-codex";
    defaultThinkingLevel = "high";
    npmCommand = [ "${piNpm}/bin/pi-npm" ];
    packages = [
      "npm:@alpino13/pi-ask"
      "npm:pi-web-search@1.3.1"
    ];
  };
  piSettingsFile = jsonFormat.generate "pi-settings.json" piSettings;
in
{
  home.packages = [
    pkgs.mcp-nixos
    pkgs.pi-coding-agent
  ];

  home.file = {
    ".pi/agent/extensions/color-swatches.ts".source = ./pi/extensions/color-swatches.ts;
    ".pi/agent/extensions/color-swatches-parser-plan.md".source =
      ./pi/extensions/color-swatches-parser-plan.md;
    ".pi/agent/extensions/lite-mode.ts".source = ./pi/extensions/lite-mode.ts;
  };

  # Write a normal file instead of a Home Manager symlink. Pi records transient
  # runtime fields such as changelog state in settings.json; each rebuild
  # reasserts this declarative configuration.
  home.activation.configurePi = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings=${lib.escapeShellArg "${config.home.homeDirectory}/.pi/agent/settings.json"}
    settings_dir="$(${pkgs.coreutils}/bin/dirname "$settings")"
    tmp="$settings.tmp"

    if [ -n "''${DRY_RUN_CMD:-}" ]; then
      echo "Would write pi settings to $settings"
    else
      ${pkgs.coreutils}/bin/mkdir -p "$settings_dir" ${lib.escapeShellArg piNpmPrefix}
      ${pkgs.coreutils}/bin/install -m 0644 ${piSettingsFile} "$tmp"
      ${pkgs.coreutils}/bin/mv "$tmp" "$settings"
    fi
  '';
}
