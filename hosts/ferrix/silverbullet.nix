{ pkgs, ... }:
{
  systemd.services.silverbullet = {
    description = "SilverBullet Markdown knowledge server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # SilverBullet is reachable only through the Tailscale firewall rule below.
    environment.SB_SHELL_BACKEND = "off";

    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/silverbullet/space";
      ExecStart = "${pkgs.silverbullet}/bin/silverbullet -L 0.0.0.0 -p 3000 /var/lib/silverbullet/space";
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

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 3000 ];
}
