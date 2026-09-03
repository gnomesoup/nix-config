{ pkgs, ... }:
{
  systemd.services.silverbullet = {
    description = "SilverBullet Markdown knowledge server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # SilverBullet stays local; Tailscale Serve terminates HTTPS for Tailnet access.
    environment.SB_SHELL_BACKEND = "off";

    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/silverbullet/space";
      ExecStart = "${pkgs.silverbullet}/bin/silverbullet -L 127.0.0.1 -p 3000 /var/lib/silverbullet/space";
      DynamicUser = true;
      StateDirectory = "silverbullet";
      StateDirectoryMode = "0750";
      WorkingDirectory = "/var/lib/silverbullet";
      Restart = "on-failure";
      RestartSec = "5s";

      CapabilityBoundingSet = "";
      LockPersonality = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
    };
  };

  # The Tailscale JSON configuration currently loses the distinction between
  # an HTTPS frontend and an HTTP backend, so configure Serve through its CLI.
  systemd.services.tailscale-serve-silverbullet = {
    description = "Tailscale Serve configuration for SilverBullet";
    wantedBy = [ "multi-user.target" ];
    after = [
      "silverbullet.service"
      "tailscaled-autoconnect.service"
      "tailscaled-set.service"
      "tailscaled.service"
    ];
    wants = [
      "silverbullet.service"
      "tailscaled.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --service=svc:silverbullet --https=443 --bg http://127.0.0.1:3000";
      ExecStop = pkgs.writeShellScript "tailscale-serve-silverbullet-stop" ''
        ${pkgs.tailscale}/bin/tailscale serve drain svc:silverbullet || true
        ${pkgs.tailscale}/bin/tailscale serve clear svc:silverbullet || true
      '';
    };
  };
}
