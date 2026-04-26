{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin isLinux;
  toYAML = lib.generators.toYAML { };

  publicConfig = {
    default = { };
  };

  publicMatches = {
    global_vars = {
      global_vars = [
        {
          name = "iso_date";
          params.format = "%F";
          type = "date";
        }
        {
          name = "local_time";
          params.format = "%T";
          type = "date";
        }
        {
          name = "iso_datetime";
          params.format = "%FT%T";
          type = "date";
        }
      ];
    };

    base = {
      matches = [
        {
          replace = "{{iso_date}}";
          trigger = ":date";
        }
        {
          replace = "{{local_time}}";
          trigger = ":time";
        }
        {
          replace = "{{iso_datetime}}";
          trigger = ":now";
        }
        {
          replace = "Espanso is working.";
          trigger = ":esp";
        }
      ];
    };
  };

  privateMatches = {
    matches = [
      {
        replace = config.sops.placeholder."mpfammatter/espanso/mem";
        trigger = ":mem";
      }
      {
        replace = config.sops.placeholder."mpfammatter/espanso/ksem";
        trigger = ":ksem";
      }
    ];
  };
in
{
  sops = {
    age.keyFile = lib.mkDefault "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    secrets."mpfammatter/espanso/mem".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/ksem".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    templates."espanso-match-private.yml".content = toYAML privateMatches;
  };

  home.activation.ensureSopsLogDirEspanso = lib.mkIf isDarwin (
    lib.hm.dag.entryBefore [ "sops-nix" ] ''
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${config.home.homeDirectory}/Library/Logs/SopsNix"}
    ''
  );

  home.activation.exportEspansoForWindows = lib.mkIf isLinux (
    lib.hm.dag.entryAfter
      [
        "linkGeneration"
        "sops-nix"
      ]
      ''
        export_dir=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/espanso-windows"}
        source_dir=${lib.escapeShellArg "${config.xdg.configHome}/espanso"}

        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$export_dir/config" "$export_dir/match"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/config/default.yml" "$export_dir/config/default.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/match/base.yml" "$export_dir/match/base.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/match/global_vars.yml" "$export_dir/match/global_vars.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -fL "$source_dir/match/private.yml" "$export_dir/match/private.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 644 \
          "$export_dir/config/default.yml" \
          "$export_dir/match/base.yml" \
          "$export_dir/match/global_vars.yml" \
          "$export_dir/match/private.yml"
      ''
  );

  xdg.configFile = {
    "espanso/config/default.yml".text = toYAML publicConfig.default;
    "espanso/match/base.yml".text = toYAML publicMatches.base;
    "espanso/match/global_vars.yml".text = toYAML publicMatches.global_vars;
    "espanso/match/private.yml".source =
      config.lib.file.mkOutOfStoreSymlink
        config.sops.templates."espanso-match-private.yml".path;
  };

  home.packages = lib.optionals isDarwin [ pkgs.espanso ];

  launchd.agents.espanso = lib.mkIf isDarwin {
    enable = true;
    config = {
      EnvironmentVariables.PATH = "${pkgs.espanso}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      KeepAlive = {
        Crashed = true;
        SuccessfulExit = false;
      };
      ProgramArguments = [
        "${pkgs.espanso}/Applications/Espanso.app/Contents/MacOS/espanso"
        "launcher"
      ];
      RunAtLoad = true;
    };
  };
}
