{ config, pkgs, ... }:

let
  home = config.users.users.mpfammatter.home;
  # The in-tree Ask questionnaire needs a terminal. Keep it for normal Pi,
  # but do not offer its non-RPC tool to agents launched by the mobile trial.
  piForPaseo = pkgs.writeShellScriptBin "pi-for-paseo" ''
    exec ${pkgs.pi-coding-agent}/bin/pi --exclude-tools ask_questions "$@"
  '';
  paseoConfig = (pkgs.formats.json { }).generate "paseo-test-config.json" {
    version = 1;
    pluginsEnabled = false;
    daemon.relay.enabled = false;
    # This is a text-chat trial; do not download local speech models on startup.
    features = {
      dictation.enabled = false;
      voiceMode.enabled = false;
    };
    agents.providers.pi = {
      enabled = true;
      command = [ "${piForPaseo}/bin/pi-for-paseo" ];
    };
  };
  start = pkgs.writeShellApplication {
    name = "start-paseo-test";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
      pkgs.tailscale
    ];
    text = ''
      umask 077
      install -d -m 0700 "$PASEO_HOME"
      # Reassert the declarative trial settings without deleting session state.
      install -m 0600 "$PASEO_CONFIG_TEMPLATE" "$PASEO_HOME/config.json"
      password_file="$PASEO_HOME/password"
      if [ ! -s "$password_file" ]; then
        openssl rand -hex 32 > "$password_file"
      fi
      chmod 0600 "$password_file"
      export PASEO_PASSWORD
      PASEO_PASSWORD="$(< "$password_file")"

      tailscale_ip="$(tailscale ip -4)"
      if [[ ! "$tailscale_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Paseo trial requires a connected Tailscale IPv4 address" >&2
        exit 1
      fi
      export PASEO_LISTEN="$tailscale_ip:6767"
      export PASEO_HOSTNAMES="ferrix,ferrix.tailbb897.ts.net,$tailscale_ip"
      exec ${pkgs.paseo}/bin/paseo daemon run
    '';
  };
in
{
  environment.systemPackages = [ pkgs.paseo ];

  # No LAN/public listener, public relay, or global firewall exception.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 6767 ];

  systemd.services.paseo-test = {
    description = "Paseo mobile-access trial for Pi";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
      "home-manager-mpfammatter.service"
    ];
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    path = [
      pkgs.pi-coding-agent
      pkgs.git
      pkgs.openssh
      pkgs.nix
      # Paseo invokes ps while managing provider subprocesses.
      pkgs.procps
      "/etc/profiles/per-user/mpfammatter"
      "/run/current-system/sw"
    ];
    environment = {
      HOME = home;
      PASEO_HOME = "${home}/.paseo-test";
      PASEO_CONFIG_TEMPLATE = "${paseoConfig}";
      PASEO_RELAY_ENABLED = "false";
    };
    serviceConfig = {
      User = "mpfammatter";
      Group = "users";
      WorkingDirectory = home;
      ExecStart = "${start}/bin/start-paseo-test";
      Restart = "on-failure";
      RestartSec = "10s";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ home ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
    };
  };
}
