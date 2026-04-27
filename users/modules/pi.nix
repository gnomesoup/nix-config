{
  config,
  lib,
  pkgs,
  ...
}:
let
  jsonFormat = pkgs.formats.json { };
  piNpmPrefix = "${config.home.homeDirectory}/.pi/agent/npm-global";
  piSettings = {
    defaultModel = "gpt-5.5";
    defaultProvider = "openai-codex";
    defaultThinkingLevel = "high";
    npmCommand = [
      "${pkgs.nodejs}/bin/npm"
      "--prefix"
      piNpmPrefix
    ];
    packages = [ "npm:@alpino13/pi-ask" ];
  };
  piSettingsFile = jsonFormat.generate "pi-settings.json" piSettings;
in
{
  home.packages = [ pkgs.pi-coding-agent ];

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
