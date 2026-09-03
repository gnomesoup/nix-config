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

  services.tailscale.serve = {
    enable = true;
    services.silverbullet.endpoints."tcp:443" = "http://127.0.0.1:3000";
  };
}
