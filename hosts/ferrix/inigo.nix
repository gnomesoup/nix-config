{
  config,
  hermesAgent,
  lib,
  pkgs,
  ...
}:

let
  tailnetHost = "ferrix.tailbb897.ts.net";
  system = pkgs.stdenv.hostPlatform.system;

  # The web dashboard hard-codes both its xterm.js font stack and responsive
  # sizes. Patch its source before Vite hashes the assets, and ship the font
  # locally so remote browsers do not depend on Google Fonts.
  patchedHermesWeb = hermesAgent.packages.${system}.web.overrideAttrs (previousAttrs: {
    patches = (previousAttrs.patches or [ ]) ++ [ ./hermes-chat-source-code-pro.patch ];
    postPatch = (previousAttrs.postPatch or "") + ''
      cp ${pkgs.source-code-pro}/share/fonts/opentype/SourceCodePro-Regular.otf \
        web/public/fonts-terminal/
      cp ${pkgs.source-code-pro}/share/fonts/opentype/SourceCodePro-Bold.otf \
        web/public/fonts-terminal/
    '';
  });

  patchedHermesPackage = hermesAgent.packages.${system}.default.overrideAttrs (previousAttrs: {
    postInstall = (previousAttrs.postInstall or "") + ''
      rm $out/share/hermes-agent/web_dist
      ln -s ${patchedHermesWeb} $out/share/hermes-agent/web_dist
    '';
    passthru = previousAttrs.passthru // {
      hermesWeb = patchedHermesWeb;
    };
  });
  inigoSilverbulletPlugin = pkgs.callPackage ./inigo-silverbullet/package.nix { };
in
{
  sops.secrets = {
    "hermes/api-server-key" = {
      owner = "inigo";
      group = "inigo";
      mode = "0400";
    };
    "hermes/dashboard-password" = {
      owner = "inigo";
      group = "inigo";
      mode = "0400";
    };
    "hermes/dashboard-secret" = {
      owner = "inigo";
      group = "inigo";
      mode = "0400";
    };
    "inigo/protonmail-bridge-email" = {
      owner = "inigo";
      group = "inigo";
      mode = "0400";
    };
    "inigo/protonmail-bridge-password" = {
      owner = "inigo";
      group = "inigo";
      mode = "0400";
    };
    "inigo/protonmail-bridge-username" = {
      owner = "inigo";
      group = "inigo";
      mode = "0400";
    };
    # A dedicated MultiSpace account token is exposed to Hermes only through
    # each unit's private systemd credential directory.
    "inigo/silverbullet-api-token" = {
      mode = "0400";
      restartUnits = [
        "hermes-agent.service"
        "hermes-backend.service"
      ];
    };
  };

  sops.templates."inigo-env" = {
    owner = "inigo";
    group = "inigo";
    mode = "0400";
    restartUnits = [
      "hermes-agent.service"
      "hermes-backend.service"
    ];
    content = ''
      API_SERVER_KEY=${config.sops.placeholder."hermes/api-server-key"}
      HASS_TOKEN=${config.sops.placeholder."inigo/home-assistant-token"}
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${config.sops.placeholder."hermes/dashboard-password"}
      HERMES_DASHBOARD_BASIC_AUTH_SECRET=${config.sops.placeholder."hermes/dashboard-secret"}
    '';
  };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    package = patchedHermesPackage;
    user = "inigo";
    group = "inigo";
    stateDir = "/var/lib/inigo";

    hermesHomeFiles."skins/spacemacs-dark.yaml" = ./inigo-spacemacs-dark.yaml;

    # The upstream default is its full package. Native mode keeps the runtime
    # reproducible; capability-gated tools activate when their backend exists.
    container.enable = false;
    workingDirectory = "/var/lib/inigo/workspace";
    environmentFiles = [ config.sops.templates."inigo-env".path ];
    extraPlugins = [ inigoSilverbulletPlugin ];
    environment = {
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = "0.0.0.0";
      API_SERVER_PORT = "8642";
      HASS_URL = "http://onderon:8123";
      HERMES_DASHBOARD_BASIC_AUTH_USERNAME = "mpfammatter";
      HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS = "43200";
    };

    settings = {
      model = {
        provider = "openai-codex";
        default = "gpt-5.6-sol";
      };
      toolsets = [ "all" ];
      timezone = "America/New_York";
      display.skin = "spacemacs-dark";

      plugins.entries."inigo-silverbullet".settings = {
        base_url = "http://127.0.0.1:3000";
        allow_insecure_http = true;
        default_space = "personal";
        spaces = {
          personal = {
            label = "Personal";
            path = "/";
            allowed_read_paths = [ "" ];
            allowed_write_paths = [ "" ];
          };
          ksp = {
            label = "KSP";
            path = "/ksp";
            allowed_read_paths = [ "" ];
            allowed_write_paths = [ "" ];
          };
        };
        max_content_bytes = 2097152;
        max_search_bytes = 67108864;
        max_result_chars = 50000;
      };

      # Bound concurrency keeps the full profile responsive on ferrix's
      # dual-core CPU while retaining delegation and background work.
      max_concurrent_sessions = 4;
      max_live_sessions = 8;
      delegation.max_concurrent_children = 2;
      gateway.api_server.max_concurrent_runs = 2;

      checkpoints = {
        enabled = true;
        max_snapshots = 10;
        max_total_size_mb = 500;
      };
      terminal = {
        backend = "local";
        font_family = "'Source Code Pro', monospace";
        timeout = 600;
      };
      telemetry.shared_metrics = {
        enabled = false;
        send = false;
      };
    };

    backend = {
      mode = "dashboard";
      host = tailnetHost;
      waitFor = "hostname";
      port = 9119;
    };

    extraPackages = with pkgs; [
      bashInteractive
      coreutils
      curl
      findutils
      gawk
      git
      gnugrep
      gnused
      himalaya
      jq
      nix
      nixfmt
      nodejs
      openssh
      python3
      ripgrep
      which
    ];
  };

  # Let the local administrator use the CLI against the service's persistent
  # sessions and state rather than accidentally creating a second profile.
  users.users.mpfammatter.extraGroups = [ "inigo" ];

  # Both endpoints are reachable only over the tailnet. The API has bearer
  # authentication and the dashboard has its own username/password gate.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    8642
    9119
  ];

  # Preserve the current assistant state when adopting the platform-neutral
  # service identity. Keep the old tree as a backup and leave a compatibility
  # symlink so persisted Hermes sessions with the former cwd remain usable.
  system.activationScripts."inigo-state-migration" = lib.stringAfter [ "hermes-agent-setup" ] ''
    if [ -d /var/lib/hermes ] && [ ! -L /var/lib/hermes ]; then
      ${pkgs.rsync}/bin/rsync -a --ignore-existing \
        --exclude '/.hermes/.env' \
        --exclude '/.hermes/.managed' \
        --exclude '/.hermes/config.yaml' \
        /var/lib/hermes/ /var/lib/inigo/

      _backup=/var/lib/hermes.pre-inigo
      if [ -e "$_backup" ]; then
        _backup="$_backup.$(${pkgs.coreutils}/bin/date +%s)"
      fi
      ${pkgs.coreutils}/bin/mv /var/lib/hermes "$_backup"
      ${pkgs.coreutils}/bin/chown -R inigo:inigo /var/lib/inigo
    fi

    if [ -L /var/lib/hermes ]; then
      ${pkgs.coreutils}/bin/ln -sfn /var/lib/inigo /var/lib/hermes
    elif [ ! -e /var/lib/hermes ]; then
      ${pkgs.coreutils}/bin/ln -s /var/lib/inigo /var/lib/hermes
    fi

    # rsync preserves the old restrictive directory modes, so restore the
    # group access promised by services.hermes-agent.addToSystemPackages.
    ${pkgs.coreutils}/bin/chmod 2770 \
      /var/lib/inigo \
      /var/lib/inigo/.hermes \
      /var/lib/inigo/workspace
    ${pkgs.coreutils}/bin/chmod 0750 /var/lib/inigo/home
    ${pkgs.findutils}/bin/find /var/lib/inigo/.hermes \
      -mindepth 1 -maxdepth 1 -type d \
      -exec ${pkgs.coreutils}/bin/chmod 2770 {} +
    ${pkgs.coreutils}/bin/install -o inigo -g inigo -m 0640 /dev/null \
      /var/lib/inigo/.migrated-from-hermes
  '';

  # Apply one aggregate resource budget to the gateway and dashboard/TUI.
  systemd.slices.inigo = {
    description = "Inigo resource limits";
    sliceConfig = {
      CPUQuota = "200%";
      CPUWeight = 50;
      IOWeight = 50;
      MemoryHigh = "4G";
      MemoryMax = "6G";
    };
  };

  systemd.services.hermes-agent.serviceConfig = {
    LoadCredential = [
      "silverbullet-api-token:${config.sops.secrets."inigo/silverbullet-api-token".path}"
    ];
    Slice = "inigo.slice";
    TasksMax = 1024;
  };
  systemd.services.hermes-backend.serviceConfig = {
    LoadCredential = [
      "silverbullet-api-token:${config.sops.secrets."inigo/silverbullet-api-token".path}"
    ];
    Slice = "inigo.slice";
    TasksMax = 1024;
  };
}
