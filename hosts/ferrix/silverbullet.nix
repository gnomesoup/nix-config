{ config, pkgs, ... }:
let
  baseUrl = "http://127.0.0.1:3000";
  tokenFile = config.sops.secrets."silverbullet/pi-api-token".path;
  calendarProxyPort = 3901;
  vimLayoutPlug = import ./silverbullet-vim-layout/package.nix { inherit pkgs; };
  iCalendarPlug = import ./silverbullet-icalendar/package.nix { inherit pkgs; };
  silverbulletPdfPlug = pkgs.fetchurl {
    url = "https://github.com/MrMugame/silverbullet-pdf/releases/download/1.1.6/silverbullet-pdf.plug.js";
    hash = "sha256-mXAR8i4JTN+W09NG2uroNtTBPs/070bhiri3FRzIExg=";
  };
  mkFileSync =
    {
      filePathOnDisk,
      filePathInSpace,
      contentType ? "application/javascript",
      spacePrefixes ? [
        [
          "Personal"
          ""
        ]
        [
          "KSP"
          "/ksp"
        ]
      ],
    }:
    pkgs.replaceVars ./silverbullet-plug-sync.py {
      inherit
        baseUrl
        contentType
        filePathInSpace
        filePathOnDisk
        tokenFile
        ;
      spacePrefixes = builtins.toJSON spacePrefixes;
    };
  vimLayoutPlugSync = mkFileSync {
    filePathOnDisk = "${vimLayoutPlug}/silverbullet-vim-layout.plug.js";
    filePathInSpace = "_plug/silverbullet-vim-layout.plug.js";
  };
  pdfPlugSync = mkFileSync {
    filePathOnDisk = silverbulletPdfPlug;
    filePathInSpace = "_plug/silverbullet-pdf.plug.js";
  };
  iCalendarPlugSync = mkFileSync {
    filePathOnDisk = "${iCalendarPlug}/icalendar.plug.js";
    filePathInSpace = "_plug/icalendar.plug.js";
  };
  personalCalendarConfig = pkgs.writeText "silverbullet-personal-calendar-config.md" ''
    ```space-lua
    config.set("icalendar", {
      sources = {
        {
          url = "http://127.0.0.1:${toString calendarProxyPort}/personal.ics",
          name = "iCloud",
        },
      },
      cacheDuration = 21600,
    })

    function calendarJournalDate()
      return string.match(editor.getCurrentPage() or "", "(%d%d%d%d%-%d%d%-%d%d)$")
    end
    ```
  '';
  kspCalendarConfig = pkgs.writeText "silverbullet-ksp-calendar-config.md" ''
    ```space-lua
    config.set("icalendar", {
      sources = {
        {
          url = "http://127.0.0.1:${toString calendarProxyPort}/ksp.ics",
          name = "Outlook",
        },
      },
      cacheDuration = 21600,
    })

    function calendarJournalDate()
      return string.match(editor.getCurrentPage() or "", "(%d%d%d%d%-%d%d%-%d%d)$")
    end
    ```
  '';
  personalCalendarConfigSync = mkFileSync {
    filePathOnDisk = personalCalendarConfig;
    filePathInSpace = "_config/icalendar.md";
    contentType = "text/markdown; charset=utf-8";
    spacePrefixes = [
      [
        "Personal"
        ""
      ]
    ];
  };
  kspCalendarConfigSync = mkFileSync {
    filePathOnDisk = kspCalendarConfig;
    filePathInSpace = "_config/icalendar.md";
    contentType = "text/markdown; charset=utf-8";
    spacePrefixes = [
      [
        "KSP"
        "/ksp"
      ]
    ];
  };
  journalTemplate = pkgs.writeText "silverbullet-journal-template.md" ''
    ---
    tags: meta/template
    frontmatter: |
      tags: journal
      date: ''${date.today()}
    ---
    ## Calendar

    ''${"$"}{query[[
      from e = index.objects("ical-event")
      where e.start:startsWith(calendarJournalDate())
      order by e.start
      select {
        Start = string.sub(e.start, 12, 16),
        Event = e.summary,
        Location = e.location
      }
    ]]}

    - |^|
  '';
  journalTemplateSync = mkFileSync {
    filePathOnDisk = journalTemplate;
    filePathInSpace = "Journal/Template.md";
    contentType = "text/markdown; charset=utf-8";
  };
  managedFilesSync = pkgs.writeShellScript "silverbullet-managed-files-sync-all" ''
    ${pkgs.python3}/bin/python3 ${vimLayoutPlugSync}
    ${pkgs.python3}/bin/python3 ${pdfPlugSync}
    ${pkgs.python3}/bin/python3 ${iCalendarPlugSync}
    ${pkgs.python3}/bin/python3 ${personalCalendarConfigSync}
    ${pkgs.python3}/bin/python3 ${kspCalendarConfigSync}
    ${pkgs.python3}/bin/python3 ${journalTemplateSync}
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
  # Calendar subscription URLs are bearer-like secrets. The browser-visible
  # plug configuration contains only fixed loopback endpoints; systemd passes
  # the real URLs to the proxy without placing them in the Nix store.
  sops.secrets."silverbullet/calendar/personal-icloud-url" = {
    mode = "0400";
    restartUnits = [ "silverbullet-calendar-proxy.service" ];
  };
  sops.secrets."silverbullet/calendar/ksp-outlook-url" = {
    mode = "0400";
    restartUnits = [ "silverbullet-calendar-proxy.service" ];
  };

  systemd.services.silverbullet-calendar-proxy = {
    description = "Private calendar feed proxy for SilverBullet";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./silverbullet-calendar-proxy.py}";
      DynamicUser = true;
      LoadCredential = [
        "personal-icloud-url:${config.sops.secrets."silverbullet/calendar/personal-icloud-url".path}"
        "ksp-outlook-url:${config.sops.secrets."silverbullet/calendar/ksp-outlook-url".path}"
      ];
      Restart = "on-failure";
      RestartSec = "5s";
      UMask = "0077";

      CapabilityBoundingSet = "";
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

  systemd.services.silverbullet = {
    description = "SilverBullet Markdown knowledge server";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "silverbullet-calendar-proxy.service"
    ];
    wants = [ "silverbullet-calendar-proxy.service" ];

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
    description = "Synchronize Nix-managed SilverBullet files";
    wantedBy = [ "multi-user.target" ];
    requires = [ "silverbullet.service" ];
    after = [ "silverbullet.service" ];
    restartTriggers = [ managedFilesSync ];
    unitConfig = {
      StartLimitIntervalSec = "5min";
      StartLimitBurst = 5;
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = managedFilesSync;
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
