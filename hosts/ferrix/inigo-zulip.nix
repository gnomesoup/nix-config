{
  hermesAgent,
  lib,
  pkgs,
  ...
}:

let
  inigoZulipPlugin = pkgs.callPackage ./inigo-zulip/package.nix {
    hermesVenv = hermesAgent.packages.${pkgs.stdenv.hostPlatform.system}.default.hermesVenv;
  };
  inigoZulipProvision = pkgs.callPackage ./zulip-inigo-provision/package.nix { };
in
{
  services.hermes-agent = {
    extraPlugins = [ inigoZulipPlugin ];
    settings.platforms.zulip = {
      enabled = true;
      gateway_restart_notification = false;
      typing_indicator = false;
      extra = {
        site = "https://chat.mmjo.com";
        bot_email = "inigo-bot@chat.mmjo.com";
        allowed_email = "michael@mmjo.com";
      };
    };
  };

  environment.systemPackages = [ inigoZulipProvision ];
  system.build.inigoZulipPlugin = inigoZulipPlugin;
  system.build.inigoZulipProvision = inigoZulipProvision;

  # The account and API key are mutable application state, never build inputs.
  # Fail closed rather than starting the gateway with an unverified bot identity.
  systemd.services.inigo-zulip-provision = {
    description = "Provision Inigo's owner-only Zulip bot";
    after = [ "zulip.service" ];
    requires = [ "zulip.service" ];
    before = [ "hermes-agent.service" ];
    requiredBy = [ "hermes-agent.service" ];
    path = [
      pkgs.coreutils
      pkgs.curl
    ];
    script = ''
      # Compose's oneshot unit is active before the application is ready.
      ready=false
      for attempt in $(seq 1 30); do
        if curl --fail --silent --max-time 5 \
          http://127.0.0.1:8080/api/v1/server_settings >/dev/null; then
          ready=true
          break
        fi
        sleep 5
      done
      if [ "$ready" != true ]; then
        echo "Zulip did not become ready; refusing bot provisioning" >&2
        exit 1
      fi
      exec ${lib.getExe inigoZulipProvision}
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      RemainAfterExit = true;
      TimeoutStartSec = "10min";
      StateDirectory = "inigo-zulip";
      StateDirectoryMode = "0700";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/inigo-zulip" ];
    };
  };

  # Only the gateway needs the bot key, not the dashboard/backend or CLI.
  systemd.services.hermes-agent = {
    after = [ "inigo-zulip-provision.service" ];
    requires = [ "inigo-zulip-provision.service" ];
    serviceConfig.LoadCredential = [
      "inigo-zulip-api-key:/var/lib/inigo-zulip/api-key"
    ];
  };
}
