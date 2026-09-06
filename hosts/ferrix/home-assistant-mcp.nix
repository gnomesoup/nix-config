{ config, pkgs, ... }:
let
  extensionConfig = pkgs.writeText "home-assistant-mcp.json" (
    builtins.toJSON {
      allowInsecureHttp = true;
      baseUrl = "http://onderon:8123";
      tokenFile = config.sops.secrets."home-assistant/pi-token".path;
    }
  );
  extension = pkgs.callPackage ../../users/modules/pi/extensions/home-assistant-mcp/package.nix {
    configFile = extensionConfig;
  };
in
{
  sops.secrets."home-assistant/pi-token" = {
    owner = "mpfammatter";
    mode = "0400";
  };

  home-manager.users.mpfammatter.home.file.".pi/agent/extensions/home-assistant-mcp".source =
    extension;
}
