{ config, pkgs, ... }:
let
  baseUrl = "http://127.0.0.1:3000";
  tokenFile = config.sops.secrets."silverbullet/pi-api-token".path;
  vimLayoutPlug = import ./silverbullet-vim-layout/package.nix { inherit pkgs; };
  silverbulletPdfPlug = pkgs.fetchurl {
    url = "https://github.com/MrMugame/silverbullet-pdf/releases/download/1.1.6/silverbullet-pdf.plug.js";
    hash = "sha256-mXAR8i4JTN+W09NG2uroNtTBPs/070bhiri3FRzIExg=";
  };
  mkPlugSync =
    {
      plugFile,
      plugPath,
    }:
    pkgs.replaceVars ./silverbullet-plug-sync.py {
      inherit
        baseUrl
        plugFile
        plugPath
        tokenFile
        ;
    };
  vimLayoutPlugSync = mkPlugSync {
    plugFile = "${vimLayoutPlug}/silverbullet-vim-layout.plug.js";
    plugPath = "_plug/silverbullet-vim-layout.plug.js";
  };
  pdfPlugSync = mkPlugSync {
    plugFile = silverbulletPdfPlug;
    plugPath = "_plug/silverbullet-pdf.plug.js";
  };
  plugSyncAll = pkgs.writeShellScript "silverbullet-plug-sync-all" ''
    ${pkgs.python3}/bin/python3 ${vimLayoutPlugSync}
    ${pkgs.python3}/bin/python3 ${pdfPlugSync}
  '';

  piExtensionConfig = pkgs.writeText "silverbullet-pi-extension.json" (
    builtins.toJSON {
      allowInsecureHttp = true;
      inherit baseUrl;
      defaultSpace = "personal";
      spaces = {
        personal = {
          label = "Personal";
          path = "/";
        };
        ksp = {
          label = "KSP";
          path = "/ksp";
        };
      };
      inherit tokenFile;
    }
  );
  piExtension = pkgs.callPackage ../../users/modules/pi/extensions/silverbullet/package.nix {
    configFile = piExtensionConfig;
  };
in
{
  # MultiSpace API tokens are created by the account owner in /.spaces and
  # materialized at activation time; only this runtime path enters the Nix store.
  sops.secrets."silverbullet/pi-api-token" = {
    owner = "mpfammatter";
    mode = "0400";
  };

  systemd.services.silverbullet = {
    description = "SilverBullet Markdown knowledge server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # SilverBullet stays local; Tailscale Serve terminates HTTPS for Tailnet access.
    environment.SB_SHELL_BACKEND = "off";

    serviceConfig = {
      ExecStart = "${pkgs.silverbullet}/bin/silverbullet -L 127.0.0.1 -p 3000 /var/lib/silverbullet";
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

  systemd.services.silverbullet-plug-sync = {
    description = "Synchronize Nix-built SilverBullet plugs";
    wantedBy = [ "multi-user.target" ];
    requires = [ "silverbullet.service" ];
    after = [ "silverbullet.service" ];
    restartTriggers = [ plugSyncAll ];
    unitConfig = {
      StartLimitIntervalSec = "5min";
      StartLimitBurst = 5;
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = plugSyncAll;
      User = "mpfammatter";
      Group = "users";
      UMask = "0077";
      TimeoutStartSec = "120s";
      Restart = "on-failure";
      RestartSec = "5s";

      CapabilityBoundingSet = "";
      IPAddressAllow = "localhost";
      IPAddressDeny = "any";
      LimitCORE = 0;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };

  home-manager.users.mpfammatter.home.file = {
    ".pi/agent/extensions/silverbullet" = {
      force = true;
      source = piExtension;
    };
    ".pi/agent/skills/silverbullet" = {
      force = true;
      source = ../../users/modules/pi/skills/silverbullet;
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
      ExecStartPre = "-${pkgs.tailscale}/bin/tailscale serve clear svc:silverbullet";
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --service=svc:silverbullet --https=443 --bg http://127.0.0.1:3000";
      ExecStop = pkgs.writeShellScript "tailscale-serve-silverbullet-stop" ''
        ${pkgs.tailscale}/bin/tailscale serve drain svc:silverbullet || true
        ${pkgs.tailscale}/bin/tailscale serve clear svc:silverbullet || true
      '';
    };
  };
}
