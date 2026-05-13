{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin isLinux;
in
{
  sops = {
    age.keyFile = lib.mkDefault "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    secrets."mpfammatter/espanso/emmm".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/emks".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/adks".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/zipks".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/phks".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/adta".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/phmm".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    secrets."mpfammatter/espanso/ksp".sopsFile = ../../secrets/mpfammatter-espanso.yaml;
    templates."espanso-match-private.yml".content = ''
      matches:
        - trigger: ":emmm"
          replace: "${config.sops.placeholder."mpfammatter/espanso/emmm"}"
        - trigger: ":emks"
          replace: "${config.sops.placeholder."mpfammatter/espanso/emks"}"
        - trigger: ":adks"
          replace: "${config.sops.placeholder."mpfammatter/espanso/adks"}"
        - trigger: ":zipks"
          replace: "${config.sops.placeholder."mpfammatter/espanso/zipks"}"
        - trigger: ":phks"
          replace: "${config.sops.placeholder."mpfammatter/espanso/phks"}"
        - trigger: ":adta"
          replace: "${config.sops.placeholder."mpfammatter/espanso/adta"}"
        - trigger: ":phmm"
          replace: "${config.sops.placeholder."mpfammatter/espanso/phmm"}"
        - trigger: ":ksp"
          replace: "${config.sops.placeholder."mpfammatter/espanso/ksp"}"
    '';
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

        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm644 -T \
          "$source_dir/config/default.yml" "$export_dir/config/default.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm644 -T \
          "$source_dir/config/remote-desktop-connection.yml" "$export_dir/config/remote-desktop-connection.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm644 -T \
          "$source_dir/match/base.yml" "$export_dir/match/base.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm644 -T \
          "$source_dir/match/global_vars.yml" "$export_dir/match/global_vars.yml"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm600 -T \
          "$source_dir/match/private.yml" "$export_dir/match/private.yml"
      ''
  );

  xdg.configFile = {
    "espanso/config/default.yml".text = ''
      search_shortcut: off
    '';
    "espanso/config/windows-app.yml" = lib.mkIf isDarwin {
      text = ''
        filter_class: "com\\.microsoft\\.rdc\\.macos"
        enable: false
      '';
    };
    "espanso/config/remote-desktop-connection.yml" = lib.mkIf isLinux {
      text = ''
        filter_exec: "(?i).*(mstsc|msrdc)\\.exe$"
        enable: false
      '';
    };
    "espanso/match/base.yml".text = ''
      matches:
        - trigger: ":date"
          replace: "{{iso_date}}"
        - trigger: ":time"
          replace: "{{local_time}}"
        - trigger: ":now"
          replace: "{{iso_datetime}}"
        - trigger: ":deg"
          replace: "°"
    '';
    "espanso/match/global_vars.yml".text = ''
      global_vars:
        - name: iso_date
          type: date
          params:
            format: "%F"
        - name: local_time
          type: date
          params:
            format: "%T"
        - name: iso_datetime
          type: date
          params:
            format: "%FT%T"
    '';
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
