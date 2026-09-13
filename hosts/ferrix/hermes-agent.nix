{
  config,
  hermesAgent,
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
in
{
  sops.secrets = {
    "hermes/api-server-key" = {
      owner = "hermes";
      group = "hermes";
      mode = "0400";
    };
    "hermes/dashboard-password" = {
      owner = "hermes";
      group = "hermes";
      mode = "0400";
    };
    "hermes/dashboard-secret" = {
      owner = "hermes";
      group = "hermes";
      mode = "0400";
    };
  };

  sops.templates."hermes-env" = {
    owner = "hermes";
    group = "hermes";
    mode = "0400";
    restartUnits = [
      "hermes-agent.service"
      "hermes-backend.service"
    ];
    content = ''
      API_SERVER_KEY=${config.sops.placeholder."hermes/api-server-key"}
      HASS_TOKEN=${config.sops.placeholder."home-assistant/pi-token"}
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${config.sops.placeholder."hermes/dashboard-password"}
      HERMES_DASHBOARD_BASIC_AUTH_SECRET=${config.sops.placeholder."hermes/dashboard-secret"}
    '';
  };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    package = patchedHermesPackage;

    hermesHomeFiles."skins/spacemacs-dark.yaml" = ./hermes-spacemacs-dark.yaml;

    # The upstream default is its full package. Native mode keeps the runtime
    # reproducible; capability-gated tools activate when their backend exists.
    container.enable = false;
    workingDirectory = "/var/lib/hermes/workspace";
    environmentFiles = [ config.sops.templates."hermes-env".path ];
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
  users.users.mpfammatter.extraGroups = [ "hermes" ];

  # Both endpoints are reachable only over the tailnet. The API has bearer
  # authentication and the dashboard has its own username/password gate.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    8642
    9119
  ];

  # Apply one aggregate resource budget to the gateway and dashboard/TUI.
  systemd.slices.hermes = {
    description = "Hermes Agent resource limits";
    sliceConfig = {
      CPUQuota = "200%";
      CPUWeight = 50;
      IOWeight = 50;
      MemoryHigh = "4G";
      MemoryMax = "6G";
    };
  };

  systemd.services.hermes-agent.serviceConfig = {
    Slice = "hermes.slice";
    TasksMax = 1024;
  };
  systemd.services.hermes-backend.serviceConfig = {
    Slice = "hermes.slice";
    TasksMax = 1024;
  };
}
