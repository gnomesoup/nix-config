{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv) isLinux;

  json = value: builtins.toJSON value + "\n";

  macStyleShortcutRemaps =
    map
      (keyCode: {
        originalKeys = "260;${toString keyCode}";
        exactMatch = false;
        operationType = 0;
        newRemapKeys = "17;${toString keyCode}";
      })
      [
        65 # A
        67 # C
        80 # P
        86 # V
        88 # X
      ];

  # Unbind Win+<number> so Weston (or other window managers) can use them
  # for workspace/tab switching without interference from PowerToys.
  westonWorkspaceUnmaps =
    map
      (keyCode: {
        originalKeys = "260;${toString keyCode}";
        exactMatch = false;
        operationType = 1;
      })
      [
        48 # 0
        49 # 1
        50 # 2
        51 # 3
        52 # 4
        53 # 5
        54 # 6
        55 # 7
        56 # 8
        57 # 9
      ];

  powerToysFiles = {
    "Keyboard Manager/default.json" = {
      remapKeys.inProcess = [ ];
      remapKeysToText.inProcess = [ ];
      remapShortcuts = {
        global = macStyleShortcutRemaps ++ westonWorkspaceUnmaps;
        appSpecific = [ ];
      };
      remapShortcutsToText = {
        global = [ ];
        appSpecific = [ ];
      };
    };

    "Keyboard Manager/settings.json" = {
      properties = {
        activeConfiguration.value = "default";
        keyboardConfigurations.value = [ "default" ];
        DefaultEditorShortcut.value = {
          win = true;
          ctrl = false;
          alt = false;
          shift = true;
          code = 81;
          key = "";
        };
        EditorShortcut.value = {
          win = true;
          ctrl = false;
          alt = false;
          shift = true;
          code = 81;
          key = "";
        };
        useNewEditor.value = false;
      };
      name = "Keyboard Manager";
      version = "1";
    };
  };
in
{
  xdg.configFile = lib.mapAttrs' (
    relativePath: value:
    lib.nameValuePair "powertoys/${relativePath}" {
      text = json value;
    }
  ) powerToysFiles;

  home.activation.exportPowerToysForWindows = lib.mkIf isLinux (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      export_dir=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/powertoys-windows"}
      source_dir=${lib.escapeShellArg "${config.xdg.configHome}/powertoys"}

      install_file() {
        relative_path="$1"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm644 -T \
          "$source_dir/$relative_path" "$export_dir/$relative_path"
      }

      ${lib.concatStringsSep "\n" (
        map (relativePath: "install_file ${lib.escapeShellArg relativePath}") (
          builtins.attrNames powerToysFiles
        )
      )}
    ''
  );
}
